import Foundation

/// Low-level JSON file operations shared by the disk store.
///
/// Every write is atomic (write-temp-then-rename), so a crash mid-write can
/// never leave a truncated JSON document behind. Append-only logs trade that
/// for cheap writes, which is safe for JSONL: a torn final line is skipped
/// on read instead of corrupting the file.
enum JSONFileIO {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func ensureDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Cannot create directory \(url.path): \(error.localizedDescription)"
            )
        }
    }

    /// Atomically writes an encodable value, creating parent directories.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Cannot encode \(T.self) for \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        do {
            try ensureDirectory(at: url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Cannot write \(url.path): \(error.localizedDescription)"
            )
        }
    }

    /// Reads and decodes a value. Returns `nil` when the file does not
    /// exist (a missing collection is an empty collection, not an error).
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let data: Data
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            data = try Data(contentsOf: url)
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Cannot read \(url.path): \(error.localizedDescription)"
            )
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Cannot decode \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /// Appends one JSONL line (newline-terminated).
    static func appendLine(_ line: Data, to url: URL) throws {
        do {
            try ensureDirectory(at: url.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var terminated = line
            if terminated.last != UInt8(ascii: "\n") {
                terminated.append(UInt8(ascii: "\n"))
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: terminated)
        } catch let error as SkynetError {
            throw error
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Cannot append to \(url.path): \(error.localizedDescription)"
            )
        }
    }

    /// Reads a JSONL file as raw line data. Missing files read as empty.
    /// Trailing whitespace and empty lines are dropped.
    static func readLines(from url: URL) throws -> [Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Cannot read \(url.path): \(error.localizedDescription)"
            )
        }
        return data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
    }

    /// Removes a file or directory if present. Missing targets are fine.
    static func remove(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone — nothing to do.
        } catch {
            throw SkynetError.persistenceFailure(
                underlying: "Cannot remove \(url.path): \(error.localizedDescription)"
            )
        }
    }
}
