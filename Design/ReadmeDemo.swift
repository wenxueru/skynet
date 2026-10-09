import AppKit
import CoreGraphics
import ImageIO
import SkynetCore
import SwiftUI
import UniformTypeIdentifiers

// Compiled beside the real UI and into the same file as the isolated AppModel.
// No real store, discovery, provider process or paid messages are used.
extension AppModel {
    func prepareReadmeDemo() {
        providers = providers.map { provider in
            var copy = provider
            copy.models = [] // Prevent the composer from launching model discovery.
            return copy
        }
        let website = Project(name: "Website", rootPath: "/workspace/website")
        let api = Project(name: "API service", rootPath: "/workspace/api")
        let docs = Project(name: "Documentation", rootPath: "/workspace/docs")
        projects = [website, api, docs]
        sessions = [
            SessionRecord(projectID: website.id, providerID: .codex, effort: .high,
                          codexApprovalMode: .manual, title: "Build a better onboarding flow"),
            SessionRecord(projectID: website.id, providerID: .claudeCode, title: "Review accessibility"),
            SessionRecord(projectID: api.id, providerID: .codex, title: "Add request validation"),
            SessionRecord(projectID: docs.id, providerID: .claudeCode, title: "Polish the quick start"),
        ]
        selectedProjectID = website.id
        selectedSessionID = sessions[0].id
        activeTurnSessionID = selectedSessionID
        liveSessionID = selectedSessionID
        let call = ToolCall(name: "exec_command", input: ["cmd": "npm test -- onboarding"])
        messages = [
            Message(origin: .user, content: [.text("Make onboarding feel simpler. Keep the changes focused and test the new flow.")]),
            Message(origin: .agent, content: [.text("I'll review the existing flow, simplify the first step, and check the tests before wrapping up.")]),
            Message(origin: .agent, content: [.toolCall(call)]),
            Message(origin: .toolResult, content: [.toolResult(toolCallID: call.id,
                content: "Onboarding suite: 12 tests passed", isError: false)]),
            Message(origin: .agent, content: [.text("### A clearer first step\n\n- One primary action instead of competing buttons.\n- Shorter labels and accessible focus states.\n- Existing validation and error messages preserved.\n\nThe onboarding tests pass. The changes are ready to review.")]),
        ]
    }

    func showReadmeQueue() {
        isRunning = true
        workingSince = Date().addingTimeInterval(-8)
        liveText = "I'm checking the keyboard navigation and focus states next."
        queuedPrompts = [
            QueuedPrompt(text: "Also check the mobile layout.", attachments: []),
            QueuedPrompt(text: "Then summarize the changes for review.", attachments: []),
        ]
    }

    func finishReadmeDemo() {
        isRunning = false
        workingSince = nil
        liveText = ""
        queuedPrompts = []
        messages.append(Message(origin: .user, content: [.text("Also check the mobile layout.")]))
        messages.append(Message(origin: .agent, content: [.text("The layout stays readable on smaller screens. Keyboard focus and the primary action remain easy to find.")]))
    }
}

private struct DemoScene: View {
    let model: AppModel
    let caption: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("SKYNET", systemImage: "sparkles").fontWeight(.semibold)
                Spacer()
                Text(caption)
                Text("OFFLINE UI DEMO").font(.caption2).fontWeight(.semibold)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.blue.opacity(0.16), in: Capsule())
            }
            .font(.caption).foregroundStyle(.secondary).padding(14)
            ContentView(model: model)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }
}

@main
@MainActor
enum ReadmeDemo {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            do { try await render() }
            catch { print("Demo rendering failed: \(error)"); exit(1) }
            app.terminate(nil)
        }
        app.run()
    }

    private static func render() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let model = AppModel()
        model.prepareReadmeDemo()
        let view = NSHostingView(rootView: DemoScene(model: model, caption: "Your coding sessions, in one native workspace"))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1320, height: 860),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Skynet — Offline README demo"
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        func capture() async throws -> CGImage {
            try await Task.sleep(for: .milliseconds(900))
            view.layoutSubtreeIfNeeded()
            // Capture only this renderer's window. View bitmap caching cannot
            // render AppKit/SwiftUI's composited sidebar and material layers.
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return image
        }
        let hero = try await capture()
        try write([hero], to: output.appendingPathComponent("workspace.png"), type: UTType.png)
        model.showReadmeQueue()
        view.rootView = DemoScene(model: model, caption: "Keep follow-ups in order • steer when priorities change")
        let queue = try await capture()
        try write([queue], to: output.appendingPathComponent("queue.png"), type: UTType.png)
        model.finishReadmeDemo()
        view.rootView = DemoScene(model: model, caption: "Readable history • focused changes • ready to review")
        let finished = try await capture()
        try write([hero, queue, finished], to: output.appendingPathComponent("workflow.gif"), type: UTType.gif)
        print("Rendered workspace.png, queue.png and workflow.gif from production SwiftUI views.")
    }

    private static func write(_ frames: [CGImage], to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                               frames.count, nil) else { throw CocoaError(.fileWriteUnknown) }
        if type == .gif {
            CGImageDestinationSetProperties(destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        for frame in frames {
            CGImageDestinationAddImage(destination, try standardSRGB(frame),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 2.5]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func standardSRGB(_ image: CGImage) throws -> CGImage {
        // Re-render pixels in a standard space; never export the display's ICC
        // profile or copy capture/source metadata into public demo assets.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return result
    }
}
