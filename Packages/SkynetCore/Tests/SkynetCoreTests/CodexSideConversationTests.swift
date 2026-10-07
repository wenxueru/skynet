import Foundation
import SkynetCore
import SkynetCoreDoubles
import Testing

@Suite("Codex side conversation")
struct CodexSideConversationTests {
    func backend(rejectFork: Bool = false) -> ScriptedExecutionBackend {
        ScriptedExecutionBackend(scripts: [.init(onStdin: { data, process in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let id = frame["id"] else { return }
            let result: JSONValue
            switch frame["method"]?.stringValue {
            case "initialize": result = [:]
            case "thread/fork":
                if rejectFork {
                    let error: JSONValue = ["id": id, "error": ["message": "fork refused"]]
                    process.emitStdout(String(data: try! JSONEncoder().encode(error), encoding: .utf8)!)
                    return
                }
                result = ["thread": ["id": "side", "ephemeral": true, "forkedFromId": "parent"]]
            case "turn/start": result = ["turn": ["id": "side-turn"]]
            default: return
            }
            let response: JSONValue = ["id": id, "result": result]
            process.emitStdout(String(data: try! JSONEncoder().encode(response), encoding: .utf8)!)
            if frame["method"]?.stringValue == "turn/start" {
                process.emitStdout(#"{"method":"item/agentMessage/delta","params":{"threadId":"parent","delta":"WRONG_PARENT"}}"#)
                process.emitStdout(#"{"method":"item/agentMessage/delta","params":{"threadId":"side","delta":"SIDE_REPLY"}}"#)
                process.emitStdout(#"{"method":"turn/completed","params":{"threadId":"side","turn":{"status":"completed"}}}"#)
            }
        })])
    }

    @Test func twoTurnsReuseOnlyEphemeralForkAndCloseOwnedProcess() async throws {
        let backend = backend()
        let side = CodexSideConversation(backend: backend, provider: .codex,
                                        parentThreadID: "parent", workingDirectory: "/tmp/skynet")
        for prompt in ["first", "second"] {
            let stream = try await side.send(AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: prompt))
            var reply = ""
            for try await event in stream { if case .textDelta(let text) = event { reply += text } }
            #expect(reply == "SIDE_REPLY")
        }
        #expect(backend.launchedRequests.count == 1)
        let process = try #require(backend.launchedProcesses.first)
        let frames = try process.stdinWrites.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        let initialize = try #require(frames.first { $0["method"]?.stringValue == "initialize" })
        #expect(initialize["id"]?.intValue == 0)
        #expect(initialize["params"]?["clientInfo"]?["title"] == .string("Skynet"))
        #expect(frames.contains { $0["method"]?.stringValue == "initialized" })
        #expect(frames.filter { $0["method"]?.stringValue == "thread/fork" }.count == 1)
        #expect(!frames.contains { $0["method"]?.stringValue == "thread/resume" })
        let fork = try #require(frames.first { $0["method"]?.stringValue == "thread/fork" })
        #expect(fork["id"]?.intValue == 1)
        #expect(fork["params"]?["threadId"] == .string("parent"))
        #expect(fork["params"]?["ephemeral"] == .bool(true))
        #expect(fork["params"]?["excludeTurns"] == .bool(true))
        let turns = frames.filter { $0["method"]?.stringValue == "turn/start" }
        #expect(turns.map { $0["id"]?.intValue } == [2, 3])
        for frame in turns {
            #expect(frame["params"]?["threadId"] == .string("side"))
            #expect(frame["params"]?["sandboxPolicy"]?["type"] == .string("readOnly"))
        }
        #expect(!process.wasTerminated)
        await side.close()
        #expect(process.wasTerminated)
    }

    @Test func forkFailureClosesConnection() async throws {
        let backend = backend(rejectFork: true)
        let side = CodexSideConversation(backend: backend, provider: .codex,
                                        parentThreadID: "parent", workingDirectory: nil)
        do {
            _ = try await side.send(AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "test"))
            Issue.record("Rejected fork must fail")
        } catch {
            #expect(String(describing: error).contains("fork refused"))
        }
        #expect(try #require(backend.launchedProcesses.first).wasTerminated)
    }

    @Test func closeDuringHandshakeEndsSendAndRejectsConcurrentTurn() async throws {
        let launched = AsyncStream<Void>.makeStream()
        let backend = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in
            launched.continuation.yield(())
            launched.continuation.finish()
        })])
        let side = CodexSideConversation(backend: backend, provider: .codex,
                                        parentThreadID: "parent", workingDirectory: nil)
        let request = AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "test")
        let sending = Task { try await side.send(request) }
        for await _ in launched.stream { break }
        do {
            _ = try await side.send(request)
            Issue.record("Concurrent side turns must be rejected")
        } catch {
            #expect(String(describing: error).contains("already running"))
        }
        await side.close()
        do {
            _ = try await sending.value
            Issue.record("Close must release a waiting send")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected close error: \(error)") }
        #expect(backend.launchedRequests.count == 1)
        #expect(try #require(backend.launchedProcesses.first).wasTerminated)
    }
}
