#if os(macOS)
import Foundation

/// Runs agent CLIs on another machine by delegating to the local `ssh`
/// client.
///
/// The heavy lifting is done by a `.local` backend (by default
/// `LocalProcessBackend`): SSHBackend only rewrites the request into an
/// `ssh host -- command` invocation and shells out. Batch mode is forced so
/// a missing key never wedges a session waiting for a password prompt that
/// will never arrive.
///
/// Note on environment: `request.environment` is applied to the *ssh
/// client* process. Propagating variables to the remote side additionally
/// requires the server's `AcceptEnv`/`PermitUserEnvironment` to allow it —
/// configure the Mac accordingly if the remote CLI needs the variables.
public struct SSHBackend: ExecutionBackend {
    public var id: BackendID
    public var displayName: String
    public let kind: ExecutionBackendKind = .ssh
    public var host: String
    public var port: Int?
    public var user: String?
    /// The `.local`-kind backend used to spawn the ssh process itself.
    /// Injected so tests can intercept the rewritten request.
    public let launcher: any ExecutionBackend

    public init(
        id: BackendID = BackendID("ssh"),
        displayName: String? = nil,
        host: String,
        port: Int? = nil,
        user: String? = nil,
        launcher: any ExecutionBackend = LocalProcessBackend()
    ) {
        precondition(
            launcher.kind == .local,
            "SSHBackend's launcher must be a local-process backend"
        )
        self.id = id
        self.displayName = displayName ?? "SSH: \(user.map { "\($0)@" } ?? "")\(host)"
        self.host = host
        self.port = port
        self.user = user
        self.launcher = launcher
    }

    public func launch(_ request: ExecutionRequest) async throws -> any ExecutionProcess {
        let sshRequest = ExecutionRequest(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(for: request, host: host, port: port, user: user),
            environment: request.environment,
            workingDirectory: nil,
            label: "ssh:\(request.label)"
        )
        return try await launcher.launch(sshRequest)
    }

    /// The argument vector for the local `ssh` invocation.
    public static func sshArguments(
        for request: ExecutionRequest,
        host: String,
        port: Int?,
        user: String?
    ) -> [String] {
        var arguments: [String] = ["-oBatchMode=yes"]
        if let user {
            arguments += ["-l", user]
        }
        if let port {
            arguments += ["-p", String(port)]
        }
        arguments += ["--", host]
        arguments.append(remoteCommand(for: request))
        return arguments
    }

    /// The command string executed on the remote host. Always routed
    /// through `sh -c` semantics (a single command string) so the working
    /// directory can apply; every token is single-quoted.
    public static func remoteCommand(for request: ExecutionRequest) -> String {
        let invocation = ([request.executable] + request.arguments)
            .map(shellQuote)
            .joined(separator: " ")
        guard let workingDirectory = request.workingDirectory, !workingDirectory.isEmpty
        else {
            return invocation
        }
        return "cd \(shellQuote(workingDirectory)) && exec \(invocation)"
    }

    /// POSIX single-quoting: everything between single quotes is literal,
    /// and an embedded quote is closed, escaped, and reopened.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
