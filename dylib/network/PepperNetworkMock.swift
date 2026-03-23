import Foundation

/// A rule that intercepts matching network requests and returns a stubbed response
/// without forwarding the request to the real server.
///
/// Mocks are stored on PepperNetworkInterceptor and checked by PepperNetworkProtocol.
/// When a request matches, a synthetic HTTP response is returned immediately.
/// Priority: mocks are checked before overrides and conditions.
struct PepperNetworkMock {
    /// Unique ID — used for replacement and removal.
    let id: String

    /// Conditions that a request must meet to be intercepted.
    let matcher: RequestMatcher

    /// HTTP status code to return (e.g. 200, 404, 500).
    let statusCode: Int

    /// Response headers. Content-Type defaults to application/json if not specified.
    let headers: [String: String]

    /// Response body data.
    let body: Data

    /// Human-readable description for status/logging.
    let description: String

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "status_code": statusCode,
            "description": description,
            "body_size": body.count,
        ]
        var m: [String: String] = [:]
        if let u = matcher.urlContains { m["url_contains"] = u }
        if let method = matcher.method { m["method"] = method }
        if let b = matcher.bodyContains { m["body_contains"] = b }
        dict["matcher"] = m
        if !headers.isEmpty {
            dict["headers"] = headers
        }
        return dict
    }
}
