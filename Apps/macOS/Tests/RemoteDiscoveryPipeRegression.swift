import Foundation
import SkynetCore

// Only the launch target is substituted. Both production discovery methods,
// decoding/error mapping and transcript-page parsing remain real source.
enum RemotePipeFixture {
    private static let lock = NSLock()
    private static var script = ""
    private static var watchdog: DispatchWorkItem?
    private static var timedOut = false

    static func configure(output: String, failure: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let encoded = Data(output.utf8).base64EncodedString()
        script = "print STDERR 'PIPE_ERROR:' . ('E' x 262144); "
            + "print STDOUT decode_base64('\(encoded)'); exit \(failure ? 7 : 0);"
        timedOut = false
    }

    static func replaceLaunch(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MMIME::Base64", "-e", script]
    }

    static func watch(_ process: Process) {
        let item = DispatchWorkItem {
            lock.lock()
            defer { lock.unlock() }
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
        }
        lock.lock()
        watchdog = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: item)
    }

    static func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        watchdog?.cancel()
        watchdog = nil
        return timedOut
    }
}

@main
private enum RemoteDiscoveryPipeRegression {
    static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    private static func run() async throws {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures.append(label) }
        }
        let host = "fixture-not-a-real-host"
        RemotePipeFixture.configure(output: #"{"provider":"codex","id":"fixture-session","title":"fixture","cwd":"/private/tmp","messages":[{"role":"user","text":"DISCOVERY_OK"}]}"# + "\n")
        let sessions = try? await RemoteSessionDiscovery.discover(host: host)
        expect(!RemotePipeFixture.finish(), "discovery large stderr exits without watchdog")
        expect(sessions?.count == 1 && sessions?.first?.providerSessionID == "fixture-session",
               "actual discovery decoder preserves session")
        expect(sessions?.first?.messages.first?.plainText == "DISCOVERY_OK",
               "actual discovery decoder preserves message")

        let record = SessionRecord(providerID: .codex, title: "fixture",
            backendID: BackendID("ssh:" + host), providerResumeToken: "fixture-session")
        RemotePipeFixture.configure(output: """
        {"cursor":31}
        {"type":"session_meta","payload":{"id":"fixture-session"}}
        {"timestamp":"2026-10-04T10:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"PAGE_OK"}]}}

        """)
        let page = try? await RemoteSessionDiscovery.transcriptPage(for: record)
        expect(!RemotePipeFixture.finish(), "page large stderr exits without watchdog")
        expect(page?.olderCursor == 31, "actual page parser preserves older cursor")
        expect(page?.session.messages.first?.plainText == "PAGE_OK", "actual page parser preserves transcript")

        for operation in ["discovery", "page"] {
            RemotePipeFixture.configure(output: "", failure: true)
            var reason: String?
            do {
                if operation == "discovery" { _ = try await RemoteSessionDiscovery.discover(host: host) }
                else { _ = try await RemoteSessionDiscovery.transcriptPage(for: record) }
            } catch SkynetError.executionFailed(let text) { reason = text }
            expect(!RemotePipeFixture.finish(), "\(operation) nonzero child exits without watchdog")
            expect(reason?.contains("PIPE_ERROR:") == true, "\(operation) failure preserves diagnostic")
            expect((reason?.utf8.count ?? 0) > 262144, "\(operation) retains full existing error semantics")
        }
        if !failures.isEmpty { throw FixtureFailure(labels: failures) }
    }

    private struct FixtureFailure: Error { let labels: [String] }
}
