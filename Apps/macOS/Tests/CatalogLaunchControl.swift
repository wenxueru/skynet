import Foundation
import Darwin
import SkynetCore

// Read-only diagnostic control. It does not start/resume a thread or a turn.
// Run from the authorized project's Terminal to compare the actual Core pipe
// transport with the GUI's failed catalog request; this is not a GUI pass.
@main
enum CatalogLaunchControl {
    static func main() async {
        let project = "/workspace/skynet"
        guard FileManager.default.currentDirectoryPath == project else {
            print("FAIL: launch this control only from the Skynet project")
            exit(64)
        }
        if CommandLine.arguments.dropFirst() == ["--parent-root"] {
            // Only this independent fixture changes its own cwd. The actual
            // backend request below still uses the original project directory.
            guard chdir("/") == 0 else { exit(1) }
            print("CORE_CATALOG fixtureParentCwd=/ childCwd=\(project)")
        } else if CommandLine.arguments.count != 1 {
            print("FAIL: unsupported control arguments")
            exit(64)
        }
        var provider = AgentProviderDescriptor.codex
        provider.executable = "/Users/example/.local/bin/codex"
        let started = ContinuousClock.now
        do {
            let catalog = try await CodexModelDiscovery.load(
                provider: provider, backend: LocalProcessBackend(),
                workingDirectory: project, timeout: .seconds(15)
            )
            let luna = catalog.models.first { $0.id.rawValue == "gpt-6-luna" }
            print("CORE_CATALOG elapsed=\(started.duration(to: .now)) models=\(catalog.models.count)")
            print("CORE_CATALOG Luna=\(luna != nil) xhigh=\(luna?.supportedEfforts.contains(.xhigh) == true)")
            guard luna?.supportedEfforts.contains(.xhigh) == true else {
                print("FAIL: Core catalog did not return Luna/xhigh metadata")
                exit(1)
            }
            print("PASS: actual Core project-cwd app-server catalog transport")
        } catch {
            print("FAIL: Core catalog transport: \(error)")
            exit(1)
        }
    }
}
