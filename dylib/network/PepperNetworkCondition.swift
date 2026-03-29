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

/// Named network condition presets based on Apple's Network Link Conditioner profiles.
enum NetworkPreset: String, CaseIterable {
    case threeG = "3G"
    case edge = "Edge"
    case lte = "LTE"
    case wifi = "WiFi"
    case highLatencyDNS = "High Latency DNS"
    case totalLoss = "100% Loss"

    /// The individual condition effects that make up this preset.
    var effects: [(effect: NetworkConditionEffect, description: String)] {
        switch self {
        case .threeG:
            return [
                (.latency(ms: 100), "3G: 100ms latency"),
                (.throttle(bytesPerSecond: 97_500), "3G: throttle 780 Kbps"),
            ]
        case .edge:
            return [
                (.latency(ms: 840), "Edge: 840ms latency"),
                (.throttle(bytesPerSecond: 30_000), "Edge: throttle 240 Kbps"),
            ]
        case .lte:
            return [
                (.latency(ms: 50), "LTE: 50ms latency"),
                (.throttle(bytesPerSecond: 6_250_000), "LTE: throttle 50 Mbps"),
            ]
        case .wifi:
            return [
                (.latency(ms: 2), "WiFi: 2ms latency"),
                (.throttle(bytesPerSecond: 5_000_000), "WiFi: throttle 40 Mbps"),
            ]
        case .highLatencyDNS:
            return [
                (.latency(ms: 3000), "High Latency DNS: 3000ms latency"),
            ]
        case .totalLoss:
            return [
                (.offline, "100% Loss: offline"),
            ]
        }
    }

    /// Case-insensitive lookup by name.
    static func named(_ name: String) -> NetworkPreset? {
        let lower = name.lowercased()
        return allCases.first { $0.rawValue.lowercased() == lower }
    }

    /// All preset names for error messages.
    static var availableNames: String {
        allCases.map { $0.rawValue }.joined(separator: ", ")
    }
}
