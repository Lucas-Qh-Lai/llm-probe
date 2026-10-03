import Foundation

public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?
    public var retry: Int?

    public var isDone: Bool {
        data.trimmingCharacters(in: .whitespaces) == "[DONE]"
    }
}

/// Incremental Server-Sent Events decoder.
///
/// Frames can be split across TCP packets, so the decoder keeps a buffer and only
/// emits complete events (terminated by a blank line).
public struct SSEDecoder: Sendable {
    private var buffer = ""
    private var pendingEvent: String?
    private var pendingData: [String] = []
    private var pendingID: String?
    private var pendingRetry: Int?

    public init() {}

    public mutating func ingest(_ data: Data) -> [SSEEvent] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        buffer += text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var events: [SSEEvent] = []
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if let event = consume(line: line) { events.append(event) }
        }
        return events
    }

    public mutating func flush() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            if let event = consume(line: buffer) { events.append(event) }
            buffer = ""
        }
        if let event = emitPending() { events.append(event) }
        return events
    }

    private mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty {
            return emitPending()
        }
        if line.hasPrefix(":") { return nil }
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": pendingEvent = value
        case "data": pendingData.append(value)
        case "id": pendingID = value
        case "retry": pendingRetry = Int(value)
        default: break
        }
        return nil
    }

    private mutating func emitPending() -> SSEEvent? {
        guard !pendingData.isEmpty || pendingEvent != nil else { return nil }
        let event = SSEEvent(
            event: pendingEvent,
            data: pendingData.joined(separator: "\n"),
            id: pendingID,
            retry: pendingRetry
        )
        pendingEvent = nil
        pendingData = []
        pendingID = nil
        pendingRetry = nil
        return event
    }
}
