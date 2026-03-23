import Foundation
import os

/// Singleton managing HTTP network interception.
/// Swizzles URLSessionConfiguration.protocolClasses so our URLProtocol
/// is injected into ALL URLSession instances (including Alamofire, etc.).
///
/// Usage:
///   PepperNetworkInterceptor.shared.install()
///   // ... app makes network requests ...
///   let recent = PepperNetworkInterceptor.shared.recentTransactions(limit: 10)
///   PepperNetworkInterceptor.shared.uninstall()
final class PepperNetworkInterceptor {
    static let shared = PepperNetworkInterceptor()

    private var logger: Logger { PepperLogger.logger(category: "network") }
    private let queue = DispatchQueue(label: "com.pepper.control.network", attributes: .concurrent)

    /// Whether interception is active. URLProtocol.canInit() gates on this.
    /// Use `isIntercepting` for thread-safe reads from outside the queue.
    private var isActive = false

    /// Thread-safe read of isActive (called from URLProtocol threads).
    var isIntercepting: Bool {
        queue.sync { isActive }
    }

    /// Whether the swizzle has been applied (never reversed).
    private var swizzleApplied = false

    /// Circular buffer of captured transactions.
    private var buffer: [NetworkTransaction] = []
    private(set) var bufferSize: Int = 500

    /// Total transactions recorded (including those evicted from buffer).
    private(set) var totalRecorded: Int = 0

    /// Number of currently in-flight HTTP requests.
    /// Incremented in PepperNetworkProtocol.startLoading(), decremented on completion.
    /// Used by PepperIdleMonitor when `include_network: true`.
    private(set) var activeRequestCount: Int = 0

    // MARK: - Duplicate Request Detection

    /// Tracks recent request keys (method+path) with timestamps for duplicate detection.
    /// Key: "GET /api/v1/pets/profile" → Value: [timestamp_ms, timestamp_ms, ...]
    private var recentRequestTimestamps: [String: [Int64]] = [:]

    /// Window in ms to consider requests as duplicates (default 3 seconds)
    private let duplicateWindowMs: Int64 = 3000

    /// Minimum count within the window to flag as duplicate
    private let duplicateThreshold: Int = 3

    /// Ring buffer of detected duplicate warnings
    private(set) var duplicateWarnings: [DuplicateRequestWarning] = []
    private let maxDuplicateWarnings = 20

    /// Registered response overrides — checked by PepperNetworkProtocol for each request.
    private var overrides: [PepperNetworkOverride] = []

    /// Active network condition rules — checked by PepperNetworkProtocol for each request.
    private var conditions: [PepperNetworkCondition] = []

    struct DuplicateRequestWarning {
        let endpoint: String  // "GET /api/pets" or "POST /graphql (GetPetProfile)"
        let count: Int
        let windowMs: Int64
        let timestamp: Date
    }

    func incrementActiveRequests() {
        queue.async(flags: .barrier) { self.activeRequestCount += 1 }
    }

    func decrementActiveRequests() {
        queue.async(flags: .barrier) { self.activeRequestCount = max(0, self.activeRequestCount - 1) }
    }

    private init() {}

    // MARK: - Lifecycle

    /// Start intercepting network traffic.
    func install(bufferSize: Int? = nil) {
        queue.async(flags: .barrier) {
            if let size = bufferSize, size > 0 {
                self.bufferSize = size
            }

            if !self.swizzleApplied {
                self.applySwizzle()
                self.swizzleApplied = true
            }

            URLProtocol.registerClass(PepperNetworkProtocol.self)
            self.isActive = true
            self.logger.info("Network interception started (buffer: \(self.bufferSize))")
        }
    }

    /// Stop intercepting (swizzle stays in place, canInit gates on isActive).
    func uninstall() {
        queue.async(flags: .barrier) {
            self.isActive = false
            URLProtocol.unregisterClass(PepperNetworkProtocol.self)
            self.logger.info("Network interception stopped")
        }
    }

    // MARK: - Response Overrides

    /// Register an override (replaces any existing override with the same ID).
    func addOverride(_ override: PepperNetworkOverride) {
        queue.async(flags: .barrier) {
            self.overrides.removeAll { $0.id == override.id }
            self.overrides.append(override)
            self.logger.info("Network override added: \(override.id) — \(override.description)")
        }
    }

    /// Remove a specific override by ID.
    func removeOverride(id: String) {
        queue.async(flags: .barrier) {
            self.overrides.removeAll { $0.id == id }
            self.logger.info("Network override removed: \(id)")
        }
    }

    /// Remove all overrides.
    func removeAllOverrides() {
        queue.async(flags: .barrier) {
            let count = self.overrides.count
            self.overrides.removeAll()
            self.logger.info("All network overrides removed (\(count))")
        }
    }

    /// Find the first override matching a request. Called by PepperNetworkProtocol.
    func matchingOverride(url: String, method: String, body: String?) -> PepperNetworkOverride? {
        queue.sync {
            overrides.first { $0.matcher.matches(url: url, method: method, body: body) }
        }
    }

    /// Snapshot of currently active overrides (for status reporting).
    var activeOverrides: [PepperNetworkOverride] {
        queue.sync { overrides }
    }

    // MARK: - Network Conditions

    /// Add a network condition rule (replaces any existing rule with the same ID).
    func addCondition(_ condition: PepperNetworkCondition) {
        queue.async(flags: .barrier) {
            self.conditions.removeAll { $0.id == condition.id }
            self.conditions.append(condition)
            self.logger.info("Network condition added: \(condition.id) — \(condition.description)")
        }
    }

    /// Remove a specific condition by ID.
    func removeCondition(id: String) {
        queue.async(flags: .barrier) {
            self.conditions.removeAll { $0.id == id }
            self.logger.info("Network condition removed: \(id)")
        }
    }

    /// Remove all conditions.
    func removeAllConditions() {
        queue.async(flags: .barrier) {
            let count = self.conditions.count
            self.conditions.removeAll()
            self.logger.info("All network conditions removed (\(count))")
        }
    }

    /// Find all conditions matching a request. Called by PepperNetworkProtocol.
    func matchingConditions(url: String, method: String, body: String?) -> [PepperNetworkCondition] {
        queue.sync {
            conditions.filter { condition in
                guard let matcher = condition.matcher else { return true }
                return matcher.matches(url: url, method: method, body: body)
            }
        }
    }

    /// Snapshot of currently active conditions (for status reporting).
    var activeConditions: [PepperNetworkCondition] {
        queue.sync { conditions }
    }

    // MARK: - Recording

    /// Record a completed transaction. Called by PepperNetworkProtocol.
    func record(_ transaction: NetworkTransaction) {
        queue.async(flags: .barrier) {
            if self.buffer.count >= self.bufferSize {
                self.buffer.removeFirst()
            }
            self.buffer.append(transaction)
            self.totalRecorded += 1

            // Record to flight recorder (lightweight summary only)
            let method = transaction.request.method
            let status = transaction.response?.statusCode ?? 0
            let durationMs = transaction.timing.durationMs ?? 0
            let bodySize = transaction.response?.originalBodySize ?? 0
            let url = transaction.request.url

            // Build compact summary: "200 POST /graphql GetPetProfile (89ms, 1.1KB)"
            var summary = "\(status) \(method)"
            let urlObj = URL(string: url)
            if let path = urlObj?.path, !path.isEmpty {
                summary += " \(path)"
            } else {
                summary += " \(url)"
            }
            if let body = transaction.request.body,
                url.hasSuffix("/graphql") || url.hasSuffix("/graphql/"),
                let opName = Self.extractGraphQLOperationName(body)
            {
                summary += " \(opName)"
            }
            summary += " (\(durationMs)ms, \(Self.formatBytes(bodySize)))"
            PepperFlightRecorder.shared.record(type: .network, summary: summary, referenceId: transaction.id)

            // Check for duplicate requests
            self.checkForDuplicates(transaction)
        }

        // Broadcast event to WebSocket clients
        let event = PepperEvent(
            event: "network_request",
            data: transaction.toDictionary()
        )
        DispatchQueue.main.async {
            PepperPlane.shared.broadcast(event)
        }
    }

    /// Check if this request is part of a duplicate pattern.
    /// Called within the barrier queue — safe to mutate recentRequestTimestamps.
    private func checkForDuplicates(_ transaction: NetworkTransaction) {
        // Build key from method + path (strip query params and host for grouping)
        let url = transaction.request.url
        let method = transaction.request.method
        let path: String
        if let urlObj = URL(string: url) {
            path = urlObj.path
        } else {
            path = url
        }

        // For GraphQL endpoints, extract the operation name from the body
        // so "POST /graphql (GetPetProfile)" and "POST /graphql (GetActivity)" are separate keys
        var key = "\(method) \(path)"
        if path.hasSuffix("/graphql") || path.hasSuffix("/graphql/") {
            if let body = transaction.request.body,
                let opName = Self.extractGraphQLOperationName(body)
            {
                key = "\(method) \(path) (\(opName))"
            }
        }
        let now = transaction.timing.startMs

        // Add timestamp and prune old entries
        var timestamps = recentRequestTimestamps[key] ?? []
        timestamps.append(now)
        timestamps = timestamps.filter { now - $0 <= duplicateWindowMs }
        recentRequestTimestamps[key] = timestamps

        // Check if we hit the threshold
        if timestamps.count >= duplicateThreshold {
            // swiftlint:disable:next force_unwrapping
            let windowActual = timestamps.last! - timestamps.first!

            // Only warn once per burst — check if we already warned for this key recently
            let alreadyWarned = duplicateWarnings.contains {
                $0.endpoint == key && Date().timeIntervalSince($0.timestamp) < 5.0
            }
            guard !alreadyWarned else { return }

            let warning = DuplicateRequestWarning(
                endpoint: key,
                count: timestamps.count,
                windowMs: windowActual,
                timestamp: Date()
            )
            duplicateWarnings.insert(warning, at: 0)
            if duplicateWarnings.count > maxDuplicateWarnings {
                duplicateWarnings.removeLast()
            }
            logger.warning("Duplicate requests: \(key) called \(timestamps.count)x in \(windowActual)ms")
        }

        // Periodically clean up stale keys (every 100 recordings)
        if totalRecorded % 100 == 0 {
            let cutoff = now - duplicateWindowMs * 2
            recentRequestTimestamps = recentRequestTimestamps.filter { _, timestamps in
                timestamps.contains { $0 > cutoff }
            }
        }
    }

    /// Get recent duplicate warnings for telemetry.
    func recentDuplicates(limit: Int = 5) -> [DuplicateRequestWarning] {
        queue.sync {
            Array(duplicateWarnings.prefix(limit))
        }
    }

    /// Get recent transactions, optionally filtered by URL substring.
    func recentTransactions(limit: Int = 50, filter: String? = nil, sinceMs: Int64? = nil) -> [NetworkTransaction] {
        queue.sync {
            var results = buffer
            if let sinceMs = sinceMs {
                results = results.filter { $0.timing.startMs >= sinceMs }
            }
            if let filter = filter, !filter.isEmpty {
                results = results.filter { $0.request.url.localizedCaseInsensitiveContains(filter) }
            }
            return Array(results.suffix(limit))
        }
    }

    /// Number of transactions in the buffer.
    var transactionCount: Int {
        queue.sync { buffer.count }
    }

    /// Clear the buffer.
    func clearBuffer() {
        queue.async(flags: .barrier) {
            self.buffer.removeAll()
            self.logger.info("Network buffer cleared")
        }
    }

    // MARK: - Swizzle

    /// Swizzle URLSessionConfiguration.protocolClasses getter so our protocol
    /// is automatically included in every URLSession config.
    private func applySwizzle() {
        let cls: AnyClass = URLSessionConfiguration.self
        let selector = NSSelectorFromString("protocolClasses")
        guard let method = class_getInstanceMethod(cls, selector) else {
            logger.error("Could not find URLSessionConfiguration.protocolClasses")
            return
        }

        let originalIMP = method_getImplementation(method)
        typealias OriginalFunc = @convention(c) (AnyObject, Selector) -> [AnyClass]?
        let original = unsafeBitCast(originalIMP, to: OriginalFunc.self)

        let block: @convention(block) (AnyObject) -> [AnyClass]? = { obj in
            var classes = original(obj, selector) ?? []
            // Only inject if not already present
            if !classes.contains(where: { $0 == PepperNetworkProtocol.self }) {
                classes.insert(PepperNetworkProtocol.self, at: 0)
            }
            return classes
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        logger.info("Swizzled URLSessionConfiguration.protocolClasses")
    }

    // MARK: - Body Processing Helpers

    /// Maximum body size before truncation (256KB).
    static let maxBodySize = 256 * 1024

    /// Content types considered text (decoded as UTF-8).
    private static let textContentTypes = [
        "text/", "application/json", "application/xml", "application/x-www-form-urlencoded",
        "application/javascript", "application/graphql", "application/ld+json",
    ]

    /// Determine if a content type is text-based.
    static func isTextContentType(_ contentType: String?) -> Bool {
        guard let ct = contentType?.lowercased() else { return false }
        return textContentTypes.contains { ct.contains($0) }
    }

    /// Process a body Data into a (string, encoding, truncated, originalSize) tuple.
    static func processBody(_ data: Data?, contentType: String?) -> (
        body: String?, encoding: String?, truncated: Bool, originalSize: Int
    ) {
        guard let data = data, !data.isEmpty else {
            return (nil, nil, false, 0)
        }

        let originalSize = data.count
        let truncated = data.count > maxBodySize
        let effectiveData = truncated ? data.prefix(maxBodySize) : data

        if isTextContentType(contentType) {
            let text =
                String(data: effectiveData, encoding: .utf8)
                ?? String(data: effectiveData, encoding: .ascii)
            return (text, nil, truncated, originalSize)
        } else {
            return (effectiveData.base64EncodedString(), "base64", truncated, originalSize)
        }
    }

    /// Extract headers as [String: String] from HTTPURLResponse.
    static func extractHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }
        return headers
    }

    /// Extract headers from URLRequest.
    static func extractRequestHeaders(_ request: URLRequest) -> [String: String] {
        request.allHTTPHeaderFields ?? [:]
    }

    /// Extract GraphQL operation name from a request body string.
    /// Handles both JSON format {"operationName": "GetPet", "query": "..."}
    /// and raw query format "query GetPet { ... }" / "mutation CreatePost { ... }"
    static func extractGraphQLOperationName(_ body: String) -> String? {
        // Try JSON format first (most common)
        if let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let opName = json["operationName"] as? String, !opName.isEmpty {
                return opName
            }
            // Try parsing from the query string
            if let query = json["query"] as? String {
                return parseOperationName(from: query)
            }
        }
        // Try raw query format
        return parseOperationName(from: body)
    }

    /// Parse operation name from a GraphQL query string.
    /// Matches: "query GetPet {" or "mutation CreatePost(" or "subscription OnUpdate {"
    private static func parseOperationName(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["query ", "mutation ", "subscription "]
        for prefix in prefixes {
            guard trimmed.hasPrefix(prefix) else { continue }
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            // Extract the name (up to the first space, paren, or brace)
            var name = ""
            for char in rest {
                if char == " " || char == "(" || char == "{" { break }
                name.append(char)
            }
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Current timestamp in milliseconds.
    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Format byte count as compact human-readable string (e.g. "1.2KB", "3.4MB").
    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1fKB", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1fMB", mb)
    }
}
