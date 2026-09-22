#if os(macOS)
import Foundation

/// Spawns agent CLIs as child processes on this Mac.
///
/// Only compiled on macOS — there is deliberately no iOS implementation.
/// Output is consumed as line streams; stdin stays open so drivers can
/// feed protocols that need it.
public final class LocalProcessBackend: ExecutionBackend {
    public let id: BackendID
    public let displayName: String
    public let kind: ExecutionBackendKind = .local

    public init(id: BackendID = BackendID("local"), displayName: String = "This Mac") {
        self.id = id
        self.displayName = displayName
    }

    public func launch(_ request: ExecutionRequest) throws -> any ExecutionProcess {
        let process = try LocalProcess(request: request)
        return process
    }

    /// Resolves an executable the way a shell would: absolute paths pass
    /// through, bare names are searched on PATH (the request's PATH, then
    /// this process's).
    public static func resolveExecutablePath(
        _ name: String,
        requestEnvironment: [String: String]
    ) -> String? {
        guard !name.contains("/") else { return name }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        let path = requestEnvironment["PATH"]
            ?? ProcessInfo.processInfo.environment["PATH"].map { "\($0):\(fallback)" }
            ?? fallback
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}

// MARK: - Process wrapper

final class LocalProcess: ExecutionProcess, @unchecked Sendable {
    let process = Process()
    let identifier: String
    let stdoutLines: AsyncThrowingStream<String, Error>
    let stderrLines: AsyncThrowingStream<String, Error>
    private let stdinHandle: FileHandle
    private let exitAwaiter = ExitAwaiter()

    init(request: ExecutionRequest) throws {
        guard
            let executablePath = LocalProcessBackend.resolveExecutablePath(
                request.executable,
                requestEnvironment: request.environment
            )
        else {
            throw SkynetError.executionFailed(
                reason:
                    "Executable \"\(request.executable)\" was not found on PATH (request \(request.label)). Install it or set an explicit executable path on the provider."
            )
        }

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in request.environment {
            environment[key] = value
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = request.arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
        if let workingDirectory = request.workingDirectory, !workingDirectory.isEmpty {
            let url = URL(fileURLWithPath: workingDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw SkynetError.executionFailed(
                    reason: "Working directory \(workingDirectory) does not exist."
                )
            }
            process.currentDirectoryURL = url
        }

        stdinHandle = stdinPipe.fileHandleForWriting
        identifier = String(ProcessInfo.processInfo.processIdentifier) + "/\(request.label)"

        let stdoutReader = LinePipeReader(handle: stdoutPipe.fileHandleForReading)
        let stderrReader = LinePipeReader(handle: stderrPipe.fileHandleForReading)
        stdoutLines = stdoutReader.stream
        stderrLines = stderrReader.stream

        do {
            try process.run()
        } catch {
            throw SkynetError.executionFailed(
                reason: "Failed to launch \(executablePath): \(error.localizedDescription)"
            )
        }

        // Setting the handler after a process already exited is defined to
        // call it immediately, so there is no exit race.
        process.terminationHandler = { [exitAwaiter] process in
            exitAwaiter.complete(process.terminationStatus)
        }
        stdoutReader.start()
        stderrReader.start()
    }

    func writeToStdin(_ data: Data) throws {
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            throw SkynetError.executionFailed(
                reason: "Writing to the agent's stdin failed: \(error.localizedDescription)"
            )
        }
    }

    func waitUntilExit() async -> Int32 {
        await exitAwaiter.wait()
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

// MARK: - Helpers

/// Bridges `Process.terminationHandler` to any number of async waiters.
final class ExitAwaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func complete(_ status: Int32) {
        let waiters = lock.withLock {
            self.status = status
            let pending = self.waiters
            self.waiters = []
            return pending
        }
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    func wait() async -> Int32 {
        if let status = lock.withLock({ self.status }) { return status }
        return await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Int32? in
                if let status { return status }
                waiters.append(continuation)
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }
}

/// Turns a pipe's file handle into a stream of newline-delimited strings.
final class LinePipeReader: @unchecked Sendable {
    let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false

    init(handle: FileHandle) {
        (stream, continuation) = AsyncThrowingStream.makeStream()
        self.handle = handle
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.handle.readabilityHandler = nil
            self.lock.unlock()
        }
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            self.lock.lock()
            if chunk.isEmpty {
                // EOF: flush any unterminated final line, then finish.
                if !self.finished {
                    self.finished = true
                    self.handle.readabilityHandler = nil
                    if !self.buffer.isEmpty {
                        self.continuation.yield(
                            String(decoding: self.buffer, as: UTF8.self)
                        )
                        self.buffer.removeAll()
                    }
                    self.continuation.finish()
                }
            } else {
                self.buffer.append(chunk)
                while let newlineIndex = self.buffer.firstIndex(
                    of: UInt8(ascii: "\n")
                ) {
                    var line = self.buffer.subdata(
                        in: self.buffer.startIndex..<newlineIndex
                    )
                    self.buffer.removeSubrange(
                        self.buffer.startIndex...newlineIndex
                    )
                    if line.last == UInt8(ascii: "\r") {
                        line.removeLast()
                    }
                    self.continuation.yield(String(decoding: line, as: UTF8.self))
                }
            }
            self.lock.unlock()
        }
    }
}
#endif
