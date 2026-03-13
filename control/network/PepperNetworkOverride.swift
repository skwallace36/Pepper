import Foundation

/// A rule that intercepts and transforms matching network responses before the app processes them.
///
/// Overrides are stored on PepperNetworkInterceptor and checked by PepperNetworkProtocol.
/// When a request matches, the response is buffered, the transform is applied, and the
/// modified data is delivered to the client instead of the original.
struct PepperNetworkOverride {
    /// Unique ID — used for replacement and removal.
    let id: String

    /// Conditions that a request must meet to be intercepted.
    let matcher: RequestMatcher

    /// Transform applied to the complete response body. Must return valid data.
    /// If the transform fails, it should return the original data unmodified (fail-safe).
    let transform: (Data) -> Data

    /// Human-readable description for status/logging.
    let description: String
}

/// Defines the conditions a request must satisfy to trigger an override.
struct RequestMatcher {
    /// URL must contain this substring (case-insensitive).
    var urlContains: String?

    /// HTTP method must match (case-insensitive).
    var method: String?

    /// Request body must contain this substring (case-insensitive).
    var bodyContains: String?

    /// Returns true if the request matches all non-nil conditions.
    func matches(url: String, method: String, body: String?) -> Bool {
        if let urlPattern = urlContains {
            guard url.localizedCaseInsensitiveContains(urlPattern) else { return false }
        }
        if let requiredMethod = self.method {
            guard method.caseInsensitiveCompare(requiredMethod) == .orderedSame else { return false }
        }
        if let bodyPattern = bodyContains {
            guard let body = body, body.localizedCaseInsensitiveContains(bodyPattern) else { return false }
        }
        return true
    }
}
