import Foundation

/// A captured HTTP transaction — request + response + timing.
struct NetworkTransaction: Codable {
    let id: String
    let request: NetworkRequestInfo
    var response: NetworkResponseInfo?
    var timing: NetworkTiming
    var error: String?

    func toDictionary(maxBody: Int? = nil) -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "request": AnyCodable(request.toDictionary(maxBody: maxBody)),
            "timing": AnyCodable(timing.toDictionary()),
        ]
        if let response = response {
            dict["response"] = AnyCodable(response.toDictionary(maxBody: maxBody))
        }
        if let error = error {
            dict["error"] = AnyCodable(error)
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

    func toDictionary(maxBody: Int? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "url": url,
            "method": method,
            "headers": headers,
            "timestamp_ms": timestampMs,
            "original_body_size": originalBodySize,
        ]
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

    func toDictionary(maxBody: Int? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "status_code": statusCode,
            "headers": headers,
            "original_body_size": originalBodySize,
            "content_length": contentLength,
        ]
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

/// Timing info for a network transaction.
struct NetworkTiming: Codable {
    let startMs: Int64
    var endMs: Int64?
    var durationMs: Int64?

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "start_ms": startMs,
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
