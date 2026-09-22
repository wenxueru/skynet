import Foundation

/// Strongly typed identifiers used across the domain model.
///
/// Every entity gets its own wrapper type so that a `SessionID` can never be
/// passed where a `ProjectID` is expected, while staying cheap `Codable`
/// values that encode as their raw representation.

/// Identifies an agent provider configuration (built-in or user-defined).
public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

/// Identifies a model within a provider's catalog.
public struct ModelID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

/// Identifies a project (a working context rooted at a directory).
public struct ProjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var value: UUID

    public init(_ value: UUID) { self.value = value }
    public init() { self.value = UUID() }

    public var description: String { value.uuidString }
}

/// Identifies an agent session within a project.
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var value: UUID

    public init(_ value: UUID) { self.value = value }
    public init() { self.value = UUID() }

    public var description: String { value.uuidString }
}

/// Identifies a message within a session.
public struct MessageID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var value: UUID

    public init(_ value: UUID) { self.value = value }
    public init() { self.value = UUID() }

    public var description: String { value.uuidString }
}

/// Identifies a tool invocation issued by an agent.
public struct ToolCallID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init() { self.rawValue = UUID().uuidString }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

/// Identifies an execution backend (local process, SSH host, relay, …).
public struct BackendID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

extension ProviderID {
    /// Built-in provider: the Codex CLI.
    public static let codex = ProviderID("codex")
    /// Built-in provider: the Claude Code CLI.
    public static let claudeCode = ProviderID("claude-code")
}

extension ProjectID {
    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension SessionID {
    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension MessageID {
    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
