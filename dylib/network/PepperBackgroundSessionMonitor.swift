import Foundation
import os

/// Captures network traffic from background URLSession tasks.
///
/// Background sessions (`URLSessionConfiguration.background(withIdentifier:)`) bypass
/// URLProtocol entirely — the system daemon (nsurlsessiond) handles the actual I/O.
/// This monitor swizzles URLSession creation to detect background sessions and wraps
/// their delegates with a proxy that records transactions from delegate callbacks.
///
/// Limitations:
/// - Request bodies are not available (background uploads use file references handled by the daemon).
/// - Timing reflects when the delegate callback fires, not the actual network timing.
/// - Only sessions created while interception is active are tracked.
final class PepperBackgroundSessionMonitor {
    static let shared = PepperBackgroundSessionMonitor()

    private var logger: Logger { PepperLogger.logger(category: "network-bg") }
    private var swizzleApplied = false
    private let lock = NSLock()

    /// Number of background sessions wrapped since install.
    private var _trackedSessions = 0

    /// Total background transactions recorded.
    private var _totalRecorded = 0

    private init() {}

    func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !swizzleApplied else { return }
        applySessionSwizzle()
        swizzleApplied = true
    }

    func recordedTransaction() {
        lock.lock()
        _totalRecorded += 1
        lock.unlock()
    }

    var trackedSessions: Int {
        lock.lock()
        defer { lock.unlock() }
        return _trackedSessions
    }

    var totalRecorded: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalRecorded
    }

    // MARK: - Swizzle

    /// Swizzle +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]
    /// to wrap delegates for background sessions.
    private func applySessionSwizzle() {
        let cls: AnyClass = URLSession.self
        let sel = NSSelectorFromString("sessionWithConfiguration:delegate:delegateQueue:")
        guard let method = class_getClassMethod(cls, sel) else {
            logger.error("Could not find +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]")
            return
        }

        let originalIMP = method_getImplementation(method)
        typealias OrigType =
            @convention(c) (
                AnyObject, Selector, URLSessionConfiguration, URLSessionDelegate?, OperationQueue?
            ) -> URLSession
        let original = unsafeBitCast(originalIMP, to: OrigType.self)

        let block:
            @convention(block) (
                AnyObject, URLSessionConfiguration, URLSessionDelegate?, OperationQueue?
            ) -> URLSession = { selfCls, config, delegate, queue in
                // Background configs have a non-nil identifier
                if config.identifier != nil,
                    PepperNetworkInterceptor.shared.isIntercepting,
                    let delegate = delegate
                {
                    let proxy = PepperBackgroundSessionProxy(wrapping: delegate)
                    PepperBackgroundSessionMonitor.shared.trackSession(
                        identifier: config.identifier ?? "?")
                    return original(selfCls, sel, config, proxy, queue)
                }
                return original(selfCls, sel, config, delegate, queue)
            }

        method_setImplementation(method, imp_implementationWithBlock(block))
        logger.info("Swizzled URLSession factory for background session monitoring")
    }

    private func trackSession(identifier: String) {
        lock.lock()
        _trackedSessions += 1
        lock.unlock()
        logger.info("Tracking background session: \(identifier)")
    }
}

// MARK: - Background Session Delegate Proxy

/// Wraps a URLSession delegate to capture traffic from background sessions.
/// Uses ObjC message forwarding to transparently proxy all delegate methods,
/// intercepting only the callbacks needed to record transactions.
final class PepperBackgroundSessionProxy: NSObject, URLSessionDelegate {

    private let original: URLSessionDelegate
    private var logger: Logger { PepperLogger.logger(category: "network-bg") }

    /// Accumulated response data per task (keyed by taskIdentifier).
    private var taskData: [Int: Data] = [:]

    /// Download file sizes per task (keyed by taskIdentifier).
    private var downloadSizes: [Int: Int64] = [:]

    private let lock = NSLock()

    init(wrapping delegate: URLSessionDelegate) {
        self.original = delegate
        super.init()
    }

    // MARK: - ObjC Forwarding

    // swiftlint:disable:next implicitly_unwrapped_optional
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return (original as AnyObject).responds(to: aSelector)
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if (original as AnyObject).responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }

    // MARK: - Intercepted Callbacks

    /// Intercept task completion to record the transaction.
    @objc(URLSession:task:didCompleteWithError:)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if PepperNetworkInterceptor.shared.isIntercepting {
            recordTransaction(for: task, error: error)
        }
        // Forward to original delegate
        if let taskDelegate = original as? URLSessionTaskDelegate {
            taskDelegate.urlSession?(session, task: task, didCompleteWithError: error)
        }
    }

    /// Accumulate response body data for data/upload tasks.
    @objc(URLSession:dataTask:didReceiveData:)
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var existing = taskData[dataTask.taskIdentifier] ?? Data()
        if existing.count < PepperNetworkInterceptor.maxBodySize {
            existing.append(data)
            taskData[dataTask.taskIdentifier] = existing
        }
        lock.unlock()

        // Forward to original delegate
        if let dataDelegate = original as? URLSessionDataDelegate {
            dataDelegate.urlSession?(session, dataTask: dataTask, didReceive: data)
        }
    }

    /// Capture download file size before forwarding.
    @objc(URLSession:downloadTask:didFinishDownloadingToURL:)
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: location.path),
            let size = attrs[.size] as? Int64
        {
            lock.lock()
            downloadSizes[downloadTask.taskIdentifier] = size
            lock.unlock()
        }

        // Forward to original — required method for download delegates
        if let downloadDelegate = original as? URLSessionDownloadDelegate {
            downloadDelegate.urlSession(
                session, downloadTask: downloadTask, didFinishDownloadingTo: location)
        }
    }

    // MARK: - Recording

    private func recordTransaction(for task: URLSessionTask, error: Error?) {
        let endMs = PepperNetworkInterceptor.nowMs()

        // Extract request info from the task
        let request = task.originalRequest ?? task.currentRequest
        let url = request?.url?.absoluteString ?? "unknown"
        let method = request?.httpMethod ?? "GET"
        let headers = request?.allHTTPHeaderFields ?? [:]

        let requestInfo = NetworkRequestInfo(
            url: url,
            method: method,
            headers: headers,
            body: nil,  // Not available for background tasks
            bodyEncoding: nil,
            bodyTruncated: false,
            originalBodySize: Int(task.countOfBytesSent),
            timestampMs: endMs
        )

        // Extract response info
        lock.lock()
        let data = taskData.removeValue(forKey: task.taskIdentifier)
        let downloadSize = downloadSizes.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        var responseInfo: NetworkResponseInfo?
        if let httpResponse = task.response as? HTTPURLResponse {
            let respHeaders = PepperNetworkInterceptor.extractHeaders(httpResponse)
            let respContentType = httpResponse.allHeaderFields["Content-Type"] as? String
            let bodySize = downloadSize ?? Int64(task.countOfBytesReceived)
            let respBody = PepperNetworkInterceptor.processBody(data, contentType: respContentType)

            responseInfo = NetworkResponseInfo(
                statusCode: httpResponse.statusCode,
                headers: respHeaders,
                body: respBody.body,
                bodyEncoding: respBody.encoding,
                bodyTruncated: respBody.truncated,
                originalBodySize: Int(bodySize),
                contentLength: httpResponse.expectedContentLength
            )
        }

        let transaction = NetworkTransaction(
            id: UUID().uuidString,
            request: requestInfo,
            response: responseInfo,
            timing: NetworkTiming(startMs: endMs, endMs: endMs, durationMs: nil),
            error: error?.localizedDescription
        )

        PepperNetworkInterceptor.shared.record(transaction)
        PepperBackgroundSessionMonitor.shared.recordedTransaction()
    }
}
