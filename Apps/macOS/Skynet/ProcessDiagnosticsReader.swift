import Foundation

/// Drain stderr while the caller reads stdout so neither pipe blocks the child.
/// One writer, with DispatchGroup completion synchronizing the final read.
final class ProcessDiagnosticsReader: @unchecked Sendable {
    private let completion = DispatchGroup()
    private var data = Data()
    private var readError: Error?
    private var truncated = false

    init(handle: FileHandle, maximumBytes: Int? = nil) {
        completion.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { completion.leave() }
            do {
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    let remaining = maximumBytes.map { $0 - data.count } ?? chunk.count
                    data.append(chunk.prefix(remaining))
                    if chunk.count > remaining { truncated = true }
                }
            } catch {
                readError = error
            }
        }
    }

    func finish() throws -> Data {
        completion.wait()
        if let readError { throw readError }
        return truncated ? data + Data("\n[Error output truncated]\n".utf8) : data
    }
}
