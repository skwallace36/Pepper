import Foundation

/// A rule that simulates adverse network conditions for matching requests.
///
/// Conditions are stored on PepperNetworkInterceptor and checked by PepperNetworkProtocol.
/// When a request matches, the condition is applied before/instead of forwarding the request.
/// Multiple conditions can match — they stack (latency adds, first fail wins, lowest throttle wins).
struct PepperNetworkCondition {
    /// Unique ID — used for replacement and removal.
    let id: String

    /// Conditions that a request must meet. Nil matcher = match all requests.
    let matcher: RequestMatcher?

    /// The type of condition to simulate.
    let effect: NetworkConditionEffect

    /// Human-readable description for status/logging.
    let description: String

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "effect": effect.name,
            "description": description,
        ]
        if let matcher = matcher {
            var m: [String: String] = [:]
            if let u = matcher.urlContains { m["url_contains"] = u }
            if let method = matcher.method { m["method"] = method }
            if let b = matcher.bodyContains { m["body_contains"] = b }
            dict["matcher"] = m
        } else {
            dict["matcher"] = "all"
        }
        dict["details"] = effect.details
        return dict
    }
}

/// The specific network condition to simulate.
enum NetworkConditionEffect {
    /// Add latency (ms) before the request is forwarded.
    case latency(ms: Int)

    /// Fail the request with an HTTP status code (synthetic response, request is not forwarded).
    case failStatus(statusCode: Int)

    /// Fail the request with an NSError (request is not forwarded).
    case failError(domain: String, code: Int)

    /// Throttle response data delivery to a maximum bytes-per-second rate.
    case throttle(bytesPerSecond: Int)

    /// Simulate offline — fail immediately with NSURLErrorNotConnectedToInternet.
    case offline

    var name: String {
        switch self {
        case .latency: return "latency"
        case .failStatus: return "fail_status"
        case .failError: return "fail_error"
        case .throttle: return "throttle"
        case .offline: return "offline"
        }
    }

    var details: [String: Any] {
        switch self {
        case .latency(let ms):
            return ["latency_ms": ms]
        case .failStatus(let code):
            return ["status_code": code]
        case .failError(let domain, let code):
            return ["error_domain": domain, "error_code": code]
        case .throttle(let bps):
            return ["bytes_per_second": bps]
        case .offline:
            return [:]
        }
    }
}
