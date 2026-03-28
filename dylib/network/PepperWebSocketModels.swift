import Foundation

/// Direction of a WebSocket frame.
enum WebSocketFrameDirection: String, Codable {
    case sent
    case received
}

/// Type of WebSocket frame content.
enum WebSocketFrameType: String, Codable {
    case text
    case binary
    case ping
    case pong
}

/// A captured WebSocket frame — one message sent or received on a connection.
struct WebSocketFrame: Codable {
    let id: String
    let connectionId: String
    let direction: WebSocketFrameDirection
    let frameType: WebSocketFrameType
    let payload: String?
    let payloadEncoding: String?
    let payloadTruncated: Bool
    let originalPayloadSize: Int
    let timestampMs: Int64
    let error: String?

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "connection_id": AnyCodable(connectionId),
            "direction": AnyCodable(direction.rawValue),
            "frame_type": AnyCodable(frameType.rawValue),
            "original_payload_size": AnyCodable(originalPayloadSize),
            "timestamp_ms": AnyCodable(timestampMs),
        ]
        if let payload = payload {
            dict["payload"] = AnyCodable(payload)
        }
        if let encoding = payloadEncoding {
            dict["payload_encoding"] = AnyCodable(encoding)
        }
        if payloadTruncated {
            dict["payload_truncated"] = AnyCodable(true)
        }
        if let error = error {
            dict["error"] = AnyCodable(error)
        }
        return dict
    }
}

/// A tracked WebSocket connection — the upgrade request + frame history.
struct WebSocketConnection {
    let id: String
    let url: String
    let startMs: Int64
    var endMs: Int64?
    var framesSent: Int = 0
    var framesReceived: Int = 0
    var bytesSent: Int = 0
    var bytesReceived: Int = 0
    var closeCode: Int?
    var closeReason: String?

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "url": AnyCodable(url),
            "start_ms": AnyCodable(startMs),
            "frames_sent": AnyCodable(framesSent),
            "frames_received": AnyCodable(framesReceived),
            "bytes_sent": AnyCodable(bytesSent),
            "bytes_received": AnyCodable(bytesReceived),
        ]
        if let endMs = endMs {
            dict["end_ms"] = AnyCodable(endMs)
        }
        if let closeCode = closeCode {
            dict["close_code"] = AnyCodable(closeCode)
        }
        if let closeReason = closeReason {
            dict["close_reason"] = AnyCodable(closeReason)
        }
        return dict
    }
}
