import Foundation

/// Arguments for macOS `open` that target a project in local or Remote-SSH VS Code.
public enum VSCodeProjectOpen {
    public static func arguments(rootPath: String?, backendID: BackendID) -> [String]? {
        guard let rootPath, !rootPath.isEmpty else { return nil }
        guard backendID.rawValue.hasPrefix("ssh:") else {
            return ["-a", "Visual Studio Code", rootPath]
        }
        let alias = String(backendID.rawValue.dropFirst("ssh:".count))
        guard !alias.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "vscode-remote"
        components.path = "/ssh-remote+\(alias)\(rootPath.hasPrefix("/") ? rootPath : "/\(rootPath)")"
        guard let url = components.url else { return nil }
        return [url.absoluteString]
    }
}
