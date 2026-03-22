import Foundation

/// iOS implementation of `NetworkInterception`.
///
/// Delegates to `PepperNetworkInterceptor.shared` (URLProtocol swizzling)
/// and converts between internal types and platform-agnostic protocol types.
final class IOSNetworkInterception: NetworkInterception {

    private let interceptor = PepperNetworkInterceptor.shared

    func install(bufferSize: Int?) {
        interceptor.install(bufferSize: bufferSize)
    }

    func uninstall() {
        interceptor.uninstall()
    }

    var isIntercepting: Bool {
        interceptor.isIntercepting
    }

    var transactionCount: Int {
        interceptor.transactionCount
    }

    var totalRecorded: Int {
        interceptor.totalRecorded
    }

    func recentTransactions(limit: Int, filter: String?, sinceMs: Int64?)
        -> [NetworkTransactionInfo]
    {
        interceptor.recentTransactions(limit: limit, filter: filter, sinceMs: sinceMs)
            .map { tx in
                NetworkTransactionInfo(
                    id: tx.id,
                    url: tx.request.url,
                    method: tx.request.method,
                    statusCode: tx.response?.statusCode,
                    requestHeaders: tx.request.headers,
                    responseHeaders: tx.response?.headers ?? [:],
                    requestBody: tx.request.body,
                    responseBody: tx.response?.body,
                    startMs: tx.timing.startMs,
                    endMs: tx.timing.endMs ?? tx.timing.startMs,
                    durationMs: tx.timing.durationMs ?? 0,
                    error: tx.error
                )
            }
    }

    func recentDuplicates(limit: Int) -> [DuplicateRequestInfo] {
        interceptor.recentDuplicates(limit: limit)
            .map { warning in
                DuplicateRequestInfo(
                    endpoint: warning.endpoint,
                    count: warning.count,
                    windowMs: warning.windowMs
                )
            }
    }

    func clearBuffer() {
        interceptor.clearBuffer()
    }

    func addOverride(_ rule: NetworkOverrideRule) {
        let override = PepperNetworkOverride(
            id: rule.id,
            matcher: RequestMatcher(
                urlContains: rule.urlContains,
                method: rule.method,
                bodyContains: rule.bodyContains
            ),
            transform: rule.transform,
            description: rule.description
        )
        interceptor.addOverride(override)
    }

    func removeOverride(id: String) {
        interceptor.removeOverride(id: id)
    }

    func removeAllOverrides() {
        interceptor.removeAllOverrides()
    }

    var activeOverrides: [NetworkOverrideRule] {
        interceptor.activeOverrides.map { override in
            NetworkOverrideRule(
                id: override.id,
                urlContains: override.matcher.urlContains,
                method: override.matcher.method,
                bodyContains: override.matcher.bodyContains,
                description: override.description,
                transform: override.transform
            )
        }
    }
}
