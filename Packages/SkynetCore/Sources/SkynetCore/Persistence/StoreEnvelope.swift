import Foundation

/// Versioned wrapper around every record SkynetCore persists.
///
/// ```json
/// { "schemaVersion": 1, "payload": { …record… } }
/// ```
///
/// The version is the contract between a file on disk and the code reading
/// it. A file written by a newer app (higher version) is *rejected*, not
/// guessed at; a file written by an older app is *migrated* up through the
/// registered migrations before decoding.
public struct StoreEnvelope: Codable, Hashable, Sendable {
    /// The schema version this build of SkynetCore reads and writes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var payload: JSONValue

    public init(schemaVersion: Int, payload: JSONValue) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    /// Wraps an encodable record into a current-version envelope.
    public static func wrap<T: Encodable>(
        _ value: T,
        schemaVersion: Int = StoreEnvelope.currentSchemaVersion
    ) throws -> StoreEnvelope {
        StoreEnvelope(schemaVersion: schemaVersion, payload: try JSONValue.wrap(value))
    }

    /// Decodes the payload back into a concrete record type.
    public func unwrap<T: Decodable>(_ type: T.Type) throws -> T {
        try payload.decode(type)
    }

    /// Parses data as an envelope and decodes its payload as `type`,
    /// migrating older payloads through `migrations` first.
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        migrations: [StoreMigration] = []
    ) throws -> T {
        let envelope: StoreEnvelope
        do {
            envelope = try JSONDecoder().decode(StoreEnvelope.self, from: data)
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Store envelope is not valid JSON: \(error.localizedDescription)"
            )
        }
        return try envelope.migrated(through: migrations).unwrap(type)
    }

    /// Brings the envelope up to `currentSchemaVersion`, or throws.
    public func migrated(through migrations: [StoreMigration]) throws -> StoreEnvelope {
        if schemaVersion > Self.currentSchemaVersion {
            throw SkynetError.unsupportedStoreSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        var current = self
        while current.schemaVersion < Self.currentSchemaVersion {
            guard
                let migration = migrations.first(where: {
                    $0.fromVersion == current.schemaVersion
                })
            else {
                throw SkynetError.unsupportedStoreSchema(
                    found: current.schemaVersion,
                    supported: Self.currentSchemaVersion
                )
            }
            current.payload = try migration.transform(current.payload)
            current.schemaVersion = migration.toVersion
        }
        return current
    }
}

/// One step of a schema upgrade, applied to the raw payload before it is
/// decoded into Swift types.
public struct StoreMigration: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    public let transform: @Sendable (JSONValue) throws -> JSONValue

    public init(
        fromVersion: Int,
        toVersion: Int,
        transform: @escaping @Sendable (JSONValue) throws -> JSONValue
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.transform = transform
    }
}

/// The migration registry used by the disk store.
///
/// Append new migrations when bumping `StoreEnvelope.currentSchemaVersion`;
/// never modify or remove existing ones — files in the wild still depend on
/// them.
public enum StoreMigrations {
    public static let standard: [StoreMigration] = []
}
