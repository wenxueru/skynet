import SkynetCore

// Compiled alongside the actual LocalProcessBackend source, in its own process.
// Default SIGPIPE disposition deliberately matches a normal GUI parent. A
// failure may terminate only this fixture; its /usr/bin/true child already exited.
@main
enum LocalProcessBrokenPipeRegression {
    static func main() async {
        setbuf(stdout, nil)
        _ = signal(SIGPIPE, SIG_DFL)
        do {
            let backend = LocalProcessBackend()
            let process = try backend.launch(ExecutionRequest(
                executable: "/usr/bin/true", arguments: [],
                workingDirectory: "/workspace/skynet",
                stdinMode: .writable, label: "owned-broken-pipe-fixture"))
            let exitCode = try await process.waitUntilExit()
            guard exitCode == 0 else { throw SkynetError.executionFailed(reason: "own child exit \(exitCode)") }
            print("CHILD: exact own process \(process.identifier) exited0 before write")
            do {
                try await process.writeToStdin(Data("late approval response\n".utf8))
                throw SkynetError.executionFailed(reason: "write after EOF unexpectedly succeeded")
            } catch let error as SkynetError {
                guard error.localizedDescription.contains("Writing to the agent's stdin failed") else { throw error }
                print("PASS: broken pipe becomes a scoped execution error, parent remains alive")
            }
            guard let local = process as? LocalProcess,
                  local.regressionNoSIGPIPE == 1 else {
                throw SkynetError.executionFailed(reason: "missing descriptor-local SIGPIPE protection")
            }
            print("PASS: actual writable descriptor has F_GETNOSIGPIPE=1")
            // Nothing changes the process-wide disposition: resetting it returns
            // the same default value. Children retain their ordinary defaults.
            let prior = signal(SIGPIPE, SIG_DFL)
            guard unsafeBitCast(prior, to: UInt.self) == unsafeBitCast(SIG_DFL, to: UInt.self) else {
                throw SkynetError.executionFailed(reason: "fixture observed a global SIGPIPE change")
            }
            print("PASS: process-wide SIGPIPE remains default")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}

extension LocalProcess {
    fileprivate var regressionNoSIGPIPE: Int32 {
        guard let stdinHandle else { return -1 }
        return fcntl(stdinHandle.fileDescriptor, F_GETNOSIGPIPE)
    }
}
