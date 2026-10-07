import Foundation

// The runner compiles the actual browser helper, exposing only its private
// command method and observing its exact Process for bounded fixture cleanup.
private enum ProcessWatchdog {
    private static let lock = NSLock()
    private static var work: DispatchWorkItem?
    private static var timedOut = false

    static func watch(_ process: Process) {
        lock.lock()
        timedOut = false
        let item = DispatchWorkItem {
            lock.lock()
            defer { lock.unlock() }
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
        }
        work = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: item)
    }

    static func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        work?.cancel()
        work = nil
        return timedOut
    }
}

@main
private enum FileCommandPipeRegression {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        let browser = SessionFileBrowser(root: "/private/tmp", backendID: nil)
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures.append(label) }
        }
        // One owned perl child per case, no shell children/account/network.
        let success = try? browser.run("/usr/bin/perl", ["-e",
            "print STDERR 'E' x 262144; print STDOUT 'PIPE_OK';"])
        expect(!ProcessWatchdog.finish(), "large stderr child exits without watchdog")
        expect(success == Data("PIPE_OK".utf8), "stdout survives large stderr")

        var diagnostic: String?
        do {
            _ = try browser.run("/usr/bin/perl", ["-e",
                "print STDERR 'FAIL_HEAD:' . ('E' x 262144); exit 7;"])
        } catch BrowserError.commandFailed(let text) { diagnostic = text }
        expect(!ProcessWatchdog.finish(), "nonzero large stderr child exits without watchdog")
        expect(diagnostic?.hasPrefix("FAIL_HEAD:") == true, "failure preserves diagnostic prefix")
        expect((diagnostic?.utf8.count ?? Int.max) <= 65562, "large diagnostic stays bounded")
        expect(diagnostic?.hasSuffix("[Error output truncated]\n") == true, "diagnostic truncation is explicit")

        var rejectedLargeOutput = false
        do {
            _ = try browser.run("/usr/bin/perl", ["-e",
                "print STDERR 'E' x 262144; print STDOUT 'O' x 5000000;"])
        } catch BrowserError.fileTooLarge { rejectedLargeOutput = true }
        expect(!ProcessWatchdog.finish(), "output-limit cleanup terminates owned child without watchdog")
        expect(rejectedLargeOutput, "existing stdout size limit retained")

        let normal = try browser.run("/usr/bin/perl", ["-e", "print STDOUT 'NORMAL';"])
        expect(!ProcessWatchdog.finish(), "normal child exits")
        expect(normal == Data("NORMAL".utf8), "normal output unchanged")
        if !failures.isEmpty { throw FixtureFailure(labels: failures) }
    }

    private struct FixtureFailure: Error { let labels: [String] }
}
