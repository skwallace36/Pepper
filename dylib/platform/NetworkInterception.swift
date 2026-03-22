import Foundation

/// Recorded HTTP transaction with request/response details and timing.
struct NetworkTransactionInfo {
    let id: String
    let url: String
    let method: String
    let statusCode: Int?
    let requestHeaders: [String: String]
    let responseHeaders: [String: String]
    let requestBody: String?
    let responseBody: String?
    let startMs: Int64
    let endMs: Int64
    let durationMs: Int64
    let error: String?
}

/// Warning about repeated identical requests within a time window.
struct DuplicateRequestInfo {
    let endpoint: String
    let count: Int
    let windowMs: Int64
}

/// Criteria for matching network requests to override.
struct NetworkOverrideRule {
    let id: String
    let urlContains: String?
    let method: String?
    let bodyContains: String?
    let description: String
    /// Transform applied to the response body data.
    let transform: (Data) -> Data
}

/// Intercepts and records HTTP traffic within the app process.
///
/// iOS implementation wraps PepperNetworkInterceptor (URLProtocol
/// swizzling). Android would use OkHttp interceptors or similar.
protocol NetworkInterception {
    /// Start intercepting network traffic.
    func install(bufferSize: Int?)

    /// Stop intercepting (recorded transactions remain available).
    func uninstall()

    /// Whether interception is currently active.
    var isIntercepting: Bool { get }

    /// Number of transactions in the buffer.
    var transactionCount: Int { get }

    /// Lifetime count of recorded transactions.
    var totalRecorded: Int { get }

    /// Query recent transactions with optional URL filter and timestamp.
    func recentTransactions(limit: Int, filter: String?, sinceMs: Int64?)
        -> [NetworkTransactionInfo]

    /// Detect repeated identical requests.
    func recentDuplicates(limit: Int) -> [DuplicateRequestInfo]

    /// Clear the transaction buffer.
    func clearBuffer()

    /// Register a response override rule.
    func addOverride(_ rule: NetworkOverrideRule)

    /// Remove an override by ID.
    func removeOverride(id: String)

    /// Remove all overrides.
    func removeAllOverrides()

    /// Snapshot of currently active overrides.
    var activeOverrides: [NetworkOverrideRule] { get }
}
