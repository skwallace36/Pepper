import Foundation

/// A captured HTTP transaction — request + response + timing.
struct NetworkTransaction: Codable {
    let id: String
    let request: NetworkRequestInfo
    var response: NetworkResponseInfo?
    var timing: NetworkTiming
    var error: String?
    /// GraphQL operation names parsed from the request body (empty if not a GraphQL request).
    var graphqlOperations: [String]?
    /// Whether this is an SSE or streaming response (text/event-stream, application/x-ndjson, etc.).
    var isStreaming: Bool = false
    /// Stream status: "open" while receiving chunks, "closed" when done.
    var streamStatus: String?
    /// Number of streaming chunks received so far.
    var chunksReceived: Int = 0
    /// Total bytes received across all streaming chunks.
    var totalStreamBytes: Int = 0
    /// Content type that triggered streaming detection (e.g. "text/event-stream").
    var streamContentType: String?

    func toDictionary(maxBody: Int? = nil, includeHeaders: Bool = true) -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "request": AnyCodable(request.toDictionary(maxBody: maxBody, includeHeaders: includeHeaders)),
            "timing": AnyCodable(timing.toDictionary()),
        ]
        if let response = response {
            dict["response"] = AnyCodable(
                response.toDictionary(maxBody: maxBody, includeHeaders: includeHeaders))
        }
        if let error = error {
            dict["error"] = AnyCodable(error)
        }
        if let ops = graphqlOperations, !ops.isEmpty {
            if ops.count == 1 {
                dict["graphql_operation"] = AnyCodable(ops[0])
            } else {
                dict["graphql_operations"] = AnyCodable(ops)
            }
        }
        if isStreaming {
            dict["is_streaming"] = AnyCodable(true)
            if let status = streamStatus {
                dict["stream_status"] = AnyCodable(status)
            }
            dict["chunks_received"] = AnyCodable(chunksReceived)
            dict["total_stream_bytes"] = AnyCodable(totalStreamBytes)
            if let ct = streamContentType {
                dict["stream_content_type"] = AnyCodable(ct)
            }
        }
        return dict
    }
}

/// Captured HTTP request metadata.
struct NetworkRequestInfo: Codable {
    let url: String
    let method: String
    let headers: [String: String]
    let body: String?
    let bodyEncoding: String?
    let bodyTruncated: Bool
    let originalBodySize: Int
    let timestampMs: Int64

    func toDictionary(maxBody: Int? = nil, includeHeaders: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            "url": url,
            "method": method,
            "timestamp_ms": timestampMs,
            "original_body_size": originalBodySize,
        ]
        if includeHeaders {
            dict["headers"] = headers
        }
        if let body = body {
            if let max = maxBody, body.count > max {
                dict["body"] = String(body.prefix(max))
                dict["body_truncated"] = true
            } else {
                dict["body"] = body
                if bodyTruncated { dict["body_truncated"] = true }
            }
        }
        if let encoding = bodyEncoding {
            dict["body_encoding"] = encoding
        }
        return dict
    }
}

/// Captured HTTP response metadata.
struct NetworkResponseInfo: Codable {
    let statusCode: Int
    let headers: [String: String]
    let body: String?
    let bodyEncoding: String?
    let bodyTruncated: Bool
    let originalBodySize: Int
    let contentLength: Int64

    func toDictionary(maxBody: Int? = nil, includeHeaders: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            "status_code": statusCode,
            "original_body_size": originalBodySize,
            "content_length": contentLength,
        ]
        if includeHeaders {
            dict["headers"] = headers
        }
        if let body = body {
            if let max = maxBody, body.count > max {
                dict["body"] = String(body.prefix(max))
                dict["body_truncated"] = true
            } else {
                dict["body"] = body
                if bodyTruncated { dict["body_truncated"] = true }
            }
        }
        if let encoding = bodyEncoding {
            dict["body_encoding"] = encoding
        }
        return dict
    }
}

/// A single chunk from an SSE or streaming response.
struct StreamingChunk: Codable {
    let index: Int
    let timestampMs: Int64
    let data: String
    let sizeBytes: Int

    func toDictionary() -> [String: Any] {
        [
            "index": index,
            "timestamp_ms": timestampMs,
            "data": data,
            "size_bytes": sizeBytes,
        ]
    }
}

/// Timing info for a network transaction.
struct NetworkTiming: Codable {
    let startMs: Int64
    var endMs: Int64?
    var durationMs: Int64?

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "start_ms": startMs
        ]
        if let endMs = endMs {
            dict["end_ms"] = endMs
        }
        if let durationMs = durationMs {
            dict["duration_ms"] = durationMs
        }
        return dict
    }
}
