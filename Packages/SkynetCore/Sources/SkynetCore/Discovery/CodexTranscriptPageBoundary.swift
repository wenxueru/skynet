import Foundation

/// Keeps Codex's prepared user response and its client-ID completion on one page.
public enum CodexTranscriptPageBoundary {
    public static let maximumPageBytes = 100 * 1024 * 1024

    public static func adjustedStart(
        in handle: FileHandle, start: UInt64, end: UInt64,
        byteLimit: Int = maximumPageBytes
    ) throws -> UInt64 {
        guard start > 0, end > start, byteLimit > 0,
              let first = try frame(in: handle, from: start, before: end, byteLimit: byteLimit),
              isUserFragment(first) else { return start }
        var turnID = first["payload"]?["turn_id"]?.stringValue
        var position = start
        let lowerBound = end > UInt64(byteLimit) ? end - UInt64(byteLimit) : 0
        while position > 0 {
            guard let previous = try previousLineStart(in: handle, before: position - 1, lowerBound: lowerBound),
                  end - previous <= UInt64(byteLimit),
                  let candidate = try frame(in: handle, from: previous, before: position, byteLimit: byteLimit)
            else { return start }
            if isUserResponse(candidate) {
                let responseTurn = candidate["payload"]?["internal_chat_message_metadata_passthrough"]?["turn_id"]?.stringValue
                guard turnID == nil || responseTurn == turnID else { return start }
                return previous
            }
            if isUserFragment(candidate) {
                if let candidateTurn = candidate["payload"]?["turn_id"]?.stringValue {
                    guard turnID == nil || turnID == candidateTurn else { return start }
                    turnID = candidateTurn
                }
            } else if candidate["type"]?.stringValue != "response_item"
                        || candidate["payload"]?["role"]?.stringValue != "user" {
                return start
            }
            position = previous
        }
        return start
    }

    private static func isUserFragment(_ frame: JSONValue) -> Bool {
        guard frame["type"]?.stringValue == "event_msg",
              let payload = frame["payload"] else { return false }
        if payload["type"]?.stringValue == "user_message" { return true }
        return ["item_started", "item_completed"].contains(payload["type"]?.stringValue ?? "")
            && payload["item"]?["type"]?.stringValue == "UserMessage"
    }

    private static func isUserResponse(_ frame: JSONValue) -> Bool {
        guard frame["type"]?.stringValue == "response_item", let payload = frame["payload"],
              payload["type"]?.stringValue == "message", payload["role"]?.stringValue == "user",
              let content = payload["content"]?.arrayValue else { return false }
        let kinds = payload["internal_chat_message_metadata_passthrough"]?["content_item_kinds"]?.arrayValue
        for (index, block) in content.enumerated() {
            if let kinds, kinds.count == content.count,
               !["user.text", "user.image"].contains(kinds[index].stringValue ?? "") { continue }
            if ["input_text", "text"].contains(block["type"]?.stringValue ?? ""),
               block["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return true
            }
            if block["type"]?.stringValue == "input_image" { return true }
        }
        return false
    }

    private static func frame(
        in handle: FileHandle, from offset: UInt64, before end: UInt64, byteLimit: Int
    ) throws -> JSONValue? {
        try handle.seek(toOffset: offset)
        var data = Data()
        while data.count < byteLimit, offset + UInt64(data.count) < end {
            let count = min(64 * 1024, byteLimit - data.count, Int(end - offset - UInt64(data.count)))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[..<newline])
                return try? JSONDecoder().decode(JSONValue.self, from: data)
            }
            data.append(chunk)
        }
        guard offset + UInt64(data.count) == end else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func previousLineStart(
        in handle: FileHandle, before offset: UInt64, lowerBound: UInt64
    ) throws -> UInt64? {
        var upper = offset
        while upper > lowerBound {
            let lower = max(lowerBound, upper > 64 * 1024 ? upper - 64 * 1024 : 0)
            try handle.seek(toOffset: lower)
            let chunk = try handle.read(upToCount: Int(upper - lower)) ?? Data()
            if let newline = chunk.lastIndex(of: 0x0A) {
                return lower + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
            }
            upper = lower
        }
        return lowerBound == 0 ? 0 : nil
    }

    /// The SSH reader uses the same bounded policy; tests compare both implementations.
    public static let pythonScript = #"""
def previous_line_start(source, offset, lower_bound=0):
    upper=offset
    while upper>lower_bound:
        lower=max(lower_bound,upper-65536)
        source.seek(lower)
        chunk=source.read(upper-lower)
        newline=chunk.rfind(b'\n')
        if newline>=0: return lower+newline+1
        upper=lower
    return 0 if lower_bound==0 else None

def codex_object(value):
    return value if isinstance(value,dict) else {}

def codex_page_frame(source, start, end, limit):
    source.seek(start)
    line=source.readline(min(limit,end-start))
    if not line.endswith(b'\n') and len(line)<end-start: return None
    try: return json.loads(line)
    except (ValueError,UnicodeDecodeError): return None

def codex_user_fragment(frame):
    if not isinstance(frame,dict) or frame.get('type')!='event_msg': return False
    payload=codex_object(frame.get('payload'))
    if payload.get('type')=='user_message': return True
    return payload.get('type') in ('item_started','item_completed') and codex_object(payload.get('item')).get('type')=='UserMessage'

def codex_user_response(frame):
    if not isinstance(frame,dict) or frame.get('type')!='response_item': return False
    payload=codex_object(frame.get('payload'))
    if payload.get('type')!='message' or payload.get('role')!='user': return False
    content=payload.get('content') or []
    if not isinstance(content,list): return False
    kinds=codex_object(payload.get('internal_chat_message_metadata_passthrough')).get('content_item_kinds')
    for index,block in enumerate(content):
        if not isinstance(block,dict): continue
        if isinstance(kinds,list) and len(kinds)==len(content) and kinds[index] not in ('user.text','user.image'): continue
        text=block.get('text')
        if block.get('type') in ('input_text','text') and isinstance(text,str) and text.strip(): return True
        if block.get('type')=='input_image': return True
    return False

def codex_page_start(source, start, end, limit=\#(maximumPageBytes)):
    if start<=0 or end<=start or limit<=0: return start
    first=codex_page_frame(source,start,end,limit)
    if not codex_user_fragment(first): return start
    turn=codex_object(first.get('payload')).get('turn_id')
    turn=turn if isinstance(turn,str) else None
    position=start
    lower_bound=max(0,end-limit)
    while position>0:
        previous=previous_line_start(source,position-1,lower_bound)
        if previous is None or end-previous>limit: return start
        candidate=codex_page_frame(source,previous,position,limit)
        if not isinstance(candidate,dict): return start
        payload=codex_object(candidate.get('payload'))
        if codex_user_response(candidate):
            response_turn=codex_object(payload.get('internal_chat_message_metadata_passthrough')).get('turn_id')
            return previous if turn is None or response_turn==turn else start
        if codex_user_fragment(candidate):
            candidate_turn=payload.get('turn_id')
            if isinstance(candidate_turn,str):
                if turn is not None and turn!=candidate_turn: return start
                turn=candidate_turn
        elif candidate.get('type')!='response_item' or payload.get('role')!='user': return start
        position=previous
    return start
"""#
}
