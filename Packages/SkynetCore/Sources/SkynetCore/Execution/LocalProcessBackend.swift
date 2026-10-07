#if os(macOS)
import Darwin
import Foundation

/// Spawns agent CLIs as child processes on this Mac.
///
/// Only compiled on macOS — there is deliberately no iOS implementation.
/// Output is consumed as line streams; stdin is writable only when requested.
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
        let path = executionPath(requestEnvironment: requestEnvironment)
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    static func executionPath(requestEnvironment: [String: String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = fallbackSearchDirectories(homeDirectory: home).joined(separator: ":")
        return requestEnvironment["PATH"]
            ?? ProcessInfo.processInfo.environment["PATH"].map { "\($0):\(fallback)" }
            ?? fallback
    }

    static func fallbackSearchDirectories(homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }
}

// MARK: - Process wrapper

final class LocalProcess: ExecutionProcess, @unchecked Sendable {
    let process = Process()
    var identifier: String { "\(process.processIdentifier)/\(label)" }
    private let label: String
    let stdoutLines: AsyncThrowingStream<String, Error>
    let stderrLines: AsyncThrowingStream<String, Error>
    private let stdinHandle: FileHandle?
    private let stdoutReader: LinePipeReader
    private let stderrReader: LinePipeReader
    private let exitAwaiter = ExitAwaiter()
    private let terminationLock = NSLock()

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
        // Finder-launched apps have a minimal PATH. Child CLI shebangs and
        // their subprocesses need the same search path as executable lookup.
        environment["PATH"] = LocalProcessBackend.executionPath(requestEnvironment: request.environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        defer {
            // Process keeps the Pipe objects as its stdio configuration.
            // Close the copies owned by this parent after launch, or EOF is
            // never delivered to the output readers when the child exits.
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        }

        if request.stdinMode == .writable {
            // Stop can race an in-flight approval/RPC reply. A broken pipe
            // must throw EPIPE, not terminate the GUI with SIGPIPE. Protect
            // only our writer descriptor; don't change global/child signals.
            guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw SkynetError.executionFailed(
                    reason: "Failed to protect agent stdin: \(String(cString: strerror(errno)))"
                )
            }
        }

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = request.arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = request.stdinMode == .closed ? FileHandle.nullDevice : stdinPipe
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

        stdinHandle = request.stdinMode == .writable ? stdinPipe.fileHandleForWriting : nil
        label = request.label

        let stdoutReader = LinePipeReader(handle: stdoutPipe.fileHandleForReading)
        let stderrReader = LinePipeReader(handle: stderrPipe.fileHandleForReading)
        self.stdoutReader = stdoutReader
        self.stderrReader = stderrReader
        stdoutLines = stdoutReader.stream
        stderrLines = stderrReader.stream

        do {
            try process.run()
        } catch {
            throw SkynetError.executionFailed(
                reason: "Failed to launch \(executablePath): \(error.localizedDescription)"
            )
        }
        if request.stdinMode == .closed {
            try? stdinPipe.fileHandleForWriting.close()
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
        guard let stdinHandle else {
            throw SkynetError.executionFailed(reason: "This process has closed stdin.")
        }
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
        terminationLock.withLock {
            guard process.isRunning else { return }
            // Agent CLIs can launch commands in separate process groups. Killing
            // only the CLI (or its group) leaves those commands running under
            // launchd, so capture its descendants before terminating the parent.
            LocalProcessTree.terminateDescendants(of: process.processIdentifier)
            process.terminate()
        }
    }
}

// MARK: - Helpers

enum LocalProcessTree {
    private struct Identity {
        let pid: pid_t
        let parent: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        init?(_ pid: pid_t) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            self.pid = pid
            parent = pid_t(info.pbi_ppid)
            startSeconds = info.pbi_start_tvsec
            startMicroseconds = info.pbi_start_tvusec
        }

        var stillMatches: Bool {
            guard let current = Identity(pid) else { return false }
            return current.parent == parent && current.startSeconds == startSeconds
                && current.startMicroseconds == startMicroseconds
        }
    }

    static func terminateDescendants(of root: pid_t) {
        var visited: Set<pid_t> = [root]
        var descendants: [Identity] = []

        func collect(_ parent: pid_t) {
            for pid in children(of: parent) where visited.insert(pid).inserted {
                guard let identity = Identity(pid), identity.parent == parent else { continue }
                collect(pid)
                descendants.append(identity)
            }
        }

        collect(root)
        // Leaf-first, while their parents still exist. Recheck both birth time
        // and parent to avoid signalling a recycled or unrelated PID.
        for identity in descendants where identity.stillMatches {
            _ = Darwin.kill(identity.pid, SIGTERM)
        }
    }

    private static func children(of parent: pid_t) -> [pid_t] {
        let stride = MemoryLayout<pid_t>.stride
        let requiredBytes = proc_listchildpids(parent, nil, 0)
        guard requiredBytes > 0 else { return [] }
        var capacity = Int(requiredBytes) / stride + 16
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
            }
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / stride
            if count < capacity { return pids.prefix(count).filter { $0 > 0 } }
            capacity *= 2
        }
    }
}

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
            var lines: [String] = []
            var finalLine: String?
            var shouldFinish = false

            self.lock.lock()
            guard !self.finished else {
                self.lock.unlock()
                return
            }

            if chunk.isEmpty {
                // EOF: flush any unterminated final line, then finish.
                self.finished = true
                self.handle.readabilityHandler = nil
                if !self.buffer.isEmpty {
                    finalLine = String(decoding: self.buffer, as: UTF8.self)
                    self.buffer.removeAll()
                }
                shouldFinish = true
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
                    lines.append(String(decoding: line, as: UTF8.self))
                }
            }
            self.lock.unlock()

            // Continuation callbacks can synchronously re-enter `onTermination`,
            // which takes the same lock. Never yield or finish while holding it.
            for line in lines {
                self.continuation.yield(line)
            }
            if let finalLine {
                self.continuation.yield(finalLine)
            }
            if shouldFinish {
                self.continuation.finish()
            }
        }
    }
}
#endif
