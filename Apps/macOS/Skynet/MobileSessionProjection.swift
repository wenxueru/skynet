import Foundation
import SkynetCore
import SkynetMobile

/// Bounded, deterministic Mac-to-mobile projections. No execution or persistence ownership.
enum MobileSessionProjection {
    static func session(_ record: SkynetCore.SessionRecord, state: SkynetMobile.TurnState) -> SkynetMobile.AgentSession {
        let effort: SkynetMobile.ReasoningEffort
        switch record.effort {
        case .low: effort = .minimal
        case .high: effort = .thorough
        case .xhigh, .max, .ultra: effort = .exhaustive
        default: effort = .standard
        }
        let permissions: SkynetMobile.PermissionMode = record.permissionEffect == .allow ? .autonomous : .askForEverything
        let config = SkynetMobile.AgentConfiguration(model: .init(
            id: record.providerID.description + "|" + (record.modelID?.description ?? "default"),
            displayName: record.modelID?.description ?? "Provider default", summary: record.providerID.description
        ), effort: effort, permissions: permissions)
        return .init(id: .init(record.id.description), projectID: .init(record.projectID?.description ?? ""),
                     title: record.title ?? "New session", createdAt: record.createdAt, updatedAt: record.updatedAt,
                     state: state, configuration: config)
    }

    static func transcript(_ messages: [SkynetCore.Message], imageData: (SkynetCore.ImageAttachment) -> Data?) -> [SkynetMobile.TranscriptItem] {
        var items: [SkynetMobile.TranscriptItem] = []
        var imageBudget = 1024 * 1024
        for message in messages.suffix(200) {
            let id = SkynetMobile.TranscriptItemID(message.id.description)
            var text = String(message.plainText.prefix(64000))
            switch message.origin {
            case .user:
                var attachments: [SkynetMobile.ImageAttachment] = []
                for block in message.content {
                    guard case .image(let image) = block else { continue }
                    let attachmentLimit = min(imageBudget, 256 * 1024)
                    let byteCount: Int
                    switch image.payload {
                    case .inline(let data, _): byteCount = data.count
                    case .blob(let reference): byteCount = reference.byteCount
                    }
                    guard byteCount >= 0, byteCount <= attachmentLimit,
                          let data = imageData(image), data.count <= attachmentLimit else {
                        text += "\n[Image omitted from mobile snapshot; view it on the Mac.]"
                        continue
                    }
                    imageBudget -= data.count
                    attachments.append(.init(id: image.id, fileName: image.fileName ?? "Image",
                                             mimeType: image.mediaType, data: data))
                }
                items.append(.userMessage(.init(id: id, text: text, attachments: attachments, sentAt: message.createdAt)))
            case .agent:
                if !text.isEmpty { items.append(.assistantMessage(.init(id: id, text: text, sentAt: message.createdAt,
                                                                         modelID: message.modelID?.description))) }
            case .system: items.append(.systemNotice(.init(id: id, text: text, date: message.createdAt)))
            case .toolResult: break
            }
            for block in message.content {
                switch block {
                case .toolCall(let call):
                    items.append(.toolCall(.init(id: .init(call.id.description), title: call.name,
                                                arguments: String(String(describing: call.input).prefix(8000)),
                                                startedAt: message.createdAt)))
                case .toolResult(let callID, let output, let failed):
                    let toolID = SkynetMobile.TranscriptItemID(callID.description)
                    let index = items.firstIndex { $0.id == toolID }
                    var tool: SkynetMobile.ToolCallRecord
                    if let index, case .toolCall(let previous) = items[index] { tool = previous }
                    else { tool = .init(id: toolID, title: "Tool result", startedAt: message.createdAt) }
                    tool.output = String(output.prefix(16000))
                    tool.outputTruncated = output.count > 16000
                    tool.state = failed ? .failed : .succeeded
                    tool.finishedAt = message.createdAt
                    if let index { items[index] = .toolCall(tool) } else { items.append(.toolCall(tool)) }
                default: break
                }
            }
        }
        return items
    }
}
