import Foundation
import SkynetCore

/// An `ExecutionBackend` that never touches the operating system: launches
/// are recorded, and each launch returns a `ScriptedProcess` playing back
/// preloaded output.
///
/// Scripts are consumed in order; when the queue runs dry the backend
/// returns a process that exits 0 with no output (a clean, empty turn).
public final class ScriptedExecutionBackend: ExecutionBackend, @unchecked Sendable {
    /// One preloaded process run.
    public struct Script: Sendable {
        public var exitCode: Int32
        public var stdoutLines: [String]
        public var stderrLines: [String]
        /// Hook invoked for every stdin write, e.g. to script a
        /// permission-ask → answer → result-frame sequence.
        public var onStdin: (@Sendable (Data, ScriptedProcess) -> Void)?

        public init(
            exitCode: Int32 = 0,
            stdoutLines: [String] = [],
            stderrLines: [String] = [],
            onStdin: (@Sendable (Data, ScriptedProcess) -> Void)? = nil
        ) {
            self.exitCode = exitCode
            self.stdoutLines = stdoutLines
            self.stderrLines = stderrLines
            self.onStdin = onStdin
        }
    }

    public var id: BackendID
    public var displayName: String
    public let kind: ExecutionBackendKind
    /// When set, every launch throws this instead of running a script.
    public var launchError: SkynetError?

    private let lock = NSLock()
    private var scripts: [Script]
    private var recordedRequests: [ExecutionRequest] = []
    private var recordedProcesses: [ScriptedProcess] = []

    public init(
        id: BackendID = BackendID("scripted"),
        displayName: String = "Scripted backend",
        kind: ExecutionBackendKind = .local,
        scripts: [Script] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.scripts = scripts
    }

    /// Queues another scripted run.
    public func enqueue(_ script: Script) {
        lock.lock()
        scripts.append(script)
        lock.unlock()
    }

    /// Every launch request, in order.
    public var launchedRequests: [ExecutionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    /// Every process this backend created, in order. Inspect
    /// `stdinWrites` on them to see what the session fed the CLI.
    public var launchedProcesses: [ScriptedProcess] {
        lock.lock()
        defer { lock.unlock() }
        return recordedProcesses
    }

    public func launch(_ request: ExecutionRequest) throws -> any ExecutionProcess {
        lock.lock()
        recordedRequests.append(request)
        let script = scripts.isEmpty ? Script() : scripts.removeFirst()
        lock.unlock()
        if let launchError {
            throw launchError
        }
        let process = ScriptedProcess(script: script, label: request.label)
        lock.lock()
        recordedProcesses.append(process)
        lock.unlock()
        return process
    }
}

/// A process that replays scripted output and records stdin writes.
public final class ScriptedProcess: ExecutionProcess, @unchecked Sendable {
    public let identifier: String
    public let stdoutLines: AsyncThrowingStream<String, Error>
    public let stderrLines: AsyncThrowingStream<String, Error>

    private let stdoutContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let stderrContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let onStdin: (@Sendable (Data, ScriptedProcess) -> Void)?
    private let lock = NSLock()
    private var recordedStdin: [Data] = []
    private var recordedTermination = false

    public private(set) var exitCode: Int32

    init(script: ScriptedExecutionBackend.Script, label: String) {
        identifier = "scripted:\(label)"
        exitCode = script.exitCode
        onStdin = script.onStdin
        (stdoutLines, stdoutContinuation) = AsyncThrowingStream.makeStream()
        (stderrLines, stderrContinuation) = AsyncThrowingStream.makeStream()
        for line in script.stdoutLines {
            stdoutContinuation.yield(line)
        }
        for line in script.stderrLines {
            stderrContinuation.yield(line)
        }
        if script.onStdin == nil {
            // No hook means no follow-up output can ever arrive; close the
            // streams so readers finish. Scripts *with* a hook keep the
            // streams open and must close them from the hook (via
            // `finishStdout`) once the conversation is scripted to its end.
            stdoutContinuation.finish()
            stderrContinuation.finish()
        }
    }

    /// All bytes written to this process's stdin, in order.
    public var stdinWrites: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStdin
    }

    /// Whether `terminate()` was called.
    public var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedTermination
    }

    /// Emits another stdout line (used by stdin hooks to script replies).
    public func emitStdout(_ line: String) {
        stdoutContinuation.yield(line)
    }

    /// Ends the stdout stream (after emitting scripted replies).
    public func finishStdout() {
        stdoutContinuation.finish()
        // A scripted process has no independent stderr producer. Closing
        // both streams models process termination and lets callers waiting
        // on the complete process lifecycle finish deterministically.
        stderrContinuation.finish()
    }

    // MARK: ExecutionProcess

    public func writeToStdin(_ data: Data) throws {
        lock.lock()
        recordedStdin.append(data)
        lock.unlock()
        onStdin?(data, self)
    }

    public func waitUntilExit() async -> Int32 {
        // The streams carry all timing; the exit status is known upfront.
        exitCode
    }

    public func terminate() {
        lock.lock()
        recordedTermination = true
        lock.unlock()
        stdoutContinuation.finish()
        stderrContinuation.finish()
    }
}
