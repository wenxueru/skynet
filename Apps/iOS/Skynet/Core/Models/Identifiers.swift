import Foundation

/// Strongly-typed identifiers used across the app's domain model.
///
/// Every identifier wraps a raw string so transports can stay wire-format
/// agnostic while call sites remain type-safe.
public struct MachineID: Hashable, Codable, Sendable, CustomStringConvertible, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

public struct ProjectID: Hashable, Codable, Sendable, CustomStringConvertible, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

public struct TranscriptItemID: Hashable, Codable, Sendable, CustomStringConvertible, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}
