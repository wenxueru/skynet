import Foundation

/// A literal host alias declared by an OpenSSH `Host` block.
public struct SSHHostDescriptor: Hashable, Sendable, Identifiable {
    public var alias: String

    public init(alias: String) {
        self.alias = alias
    }

    public var id: BackendID { BackendID("ssh:\(alias)") }
    public var displayName: String { alias }
}

public enum SSHConfigParser {
    /// Returns literal aliases in declaration order. Wildcard and negated
    /// patterns configure matching but do not represent connectable machines.
    public static func hosts(in text: String) -> [SSHHostDescriptor] {
        var seen: Set<String> = []
        var hosts: [SSHHostDescriptor] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard fields.first?.lowercased() == "host" else { continue }
            for alias in fields.dropFirst()
            where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                if seen.insert(alias).inserted {
                    hosts.append(SSHHostDescriptor(alias: alias))
                }
            }
        }
        return hosts
    }
}
