import Foundation

/// Which flavor of execution a backend performs. The platform policy keys
/// off this at runtime; the local/SSH *types* additionally exist only on
/// macOS, making the boundary compile-time as well.
public enum ExecutionBackendKind: String, Codable, Sendable, Hashable {
    /// Spawn a process on this machine (macOS only).
    case local
    /// Spawn a process on a remote machine via `ssh` (macOS only).
    case ssh
    /// Forward execution to a paired Mac over an encrypted relay.
    /// The only kind available on iOS.
    case relay
}

/// A process launch request, expressed in backend-neutral terms.
public struct ExecutionRequest: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    /// Diagnostic label used in logs and errors, e.g.
    /// `claude-code:session-42`.
    public var label: String

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        label: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.label = label
    }
}

/// A running process, abstracted to the two things the drivers need:
/// line-oriented output and writeable stdin.
public protocol ExecutionProcess: Sendable {
    /// Stable identifier for logs. For local processes this is the PID.
    var identifier: String { get }

    /// Standard output as a stream of newline-delimited strings.
    /// Lines are stripped of their terminator. The stream finishes when the
    /// pipe closes or the process exits.
    var stdoutLines: AsyncThrowingStream<String, Error> { get }

    /// Standard error, same shape as `stdoutLines`.
    var stderrLines: AsyncThrowingStream<String, Error> { get }

    /// Writes raw bytes to the process's standard input.
    func writeToStdin(_ data: Data) async throws

    /// Waits for termination and returns the exit status.
    func waitUntilExit() async throws -> Int32

    /// Asks the process to terminate (SIGTERM).
    func terminate() async
}

/// Where and how an agent process runs.
///
/// Implementations: `LocalProcessBackend` and `SSHBackend` (macOS only),
/// `RelayBackend` (macOS and iOS). Backends are values — configuration in,
/// processes out — and carry no per-session state.
public protocol ExecutionBackend: Sendable {
    var id: BackendID { get }
    var displayName: String { get }
    var kind: ExecutionBackendKind { get }

    /// Launches a process. Throws `SkynetError.executionFailed` when the
    /// launch itself fails (missing executable, refused connection).
    func launch(_ request: ExecutionRequest) async throws -> any ExecutionProcess
}
