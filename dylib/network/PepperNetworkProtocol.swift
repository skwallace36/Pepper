import Foundation
import os

/// URLProtocol subclass that captures HTTP traffic.
/// Injected into all URLSessionConfigurations via swizzle in PepperNetworkInterceptor.
final class PepperNetworkProtocol: URLProtocol {

    /// Property key used to mark requests as already handled (prevent recursion).
    private static let handledKey = "com.pepper.control.network.handled"

    private var logger: Logger { PepperLogger.logger(category: "network-proto") }

    /// The forwarding URLSession (ephemeral, without our protocol).
    private var dataTask: URLSessionDataTask?
    private var forwardSession: URLSession?

    /// Accumulated response data.
    private var responseData = Data()

    /// Captured HTTP response.
    private var httpResponse: HTTPURLResponse?

    /// Captured request body (read at startLoading before the stream is consumed).
    private var capturedRequestBody: Data?

    /// If non-nil, this request matched a mock — return synthetic response without forwarding.
    private var matchedMock: PepperNetworkMock?

    /// If non-nil, this request matched an override — buffer response and apply transform.
    private var matchedOverride: PepperNetworkOverride?

    /// Matched network conditions for this request (latency, throttle, etc.).
    private var matchedConditions: [PepperNetworkCondition] = []

    /// Whether this response is a streaming/SSE response (detected from Content-Type).
    private var isStreaming = false

    /// Whether we've already recorded the initial streaming transaction.
    private var streamingRecorded = false

    /// Transaction ID for correlation.
    private let transactionId = UUID().uuidString

    /// Start timestamp.
    private let startMs = PepperNetworkInterceptor.nowMs()

    // MARK: - Body Stream Reader

    /// Read an InputStream into Data. Used when httpBody is nil but httpBodyStream exists.
    /// Reads up to maxBodySize bytes to avoid huge allocations.
    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream = stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 { break }  // stream error
            if bytesRead == 0 { break }  // EOF
            data.append(buffer, count: bytesRead)
            if data.count > PepperNetworkInterceptor.maxBodySize { break }
        }

        return data.isEmpty ? nil : data
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        // Gate on active flag
        guard PepperNetworkInterceptor.shared.isIntercepting else { return false }

        // Only HTTP/HTTPS
        guard let scheme = request.url?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return false }

        // Skip already-handled requests
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }

        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        PepperNetworkInterceptor.shared.incrementActiveRequests()

        // Capture request body NOW before the stream gets consumed.
        // httpBody is nil when the request uses httpBodyStream (Alamofire, etc.)
        capturedRequestBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)

        // Check if this request matches a mock, override, or condition
        let url = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"
        let bodyString: String? = capturedRequestBody.flatMap { String(data: $0, encoding: .utf8) }

        // Priority: mocks first (full synthetic response, no network)
        matchedMock = PepperNetworkInterceptor.shared.matchingMock(
            url: url, method: method, body: bodyString
        )
        if let mock = matchedMock {
            applyMock(mock, url: url, method: method)
            return
        }

        matchedOverride = PepperNetworkInterceptor.shared.matchingOverride(
            url: url, method: method, body: bodyString
        )

        // Check for network condition rules
        matchedConditions = PepperNetworkInterceptor.shared.matchingConditions(
            url: url, method: method, body: bodyString
        )

        // Check for blocking conditions (offline, fail) — these short-circuit the request
        if let blockingEffect = firstBlockingEffect() {
            applyBlockingEffect(blockingEffect, url: url, method: method)
            return
        }

        // Calculate total latency from all matching latency conditions
        let totalLatencyMs = matchedConditions.reduce(0) { total, condition in
            if case .latency(let ms) = condition.effect { return total + ms }
            return total
        }

        // Mark the request so we don't intercept it again
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        // Create an ephemeral session without our protocol to avoid recursion
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = config.protocolClasses?.filter { $0 != PepperNetworkProtocol.self }
        forwardSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        dataTask = forwardSession?.dataTask(with: mutableRequest as URLRequest)

        // Apply latency delay if any
        if totalLatencyMs > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(totalLatencyMs)) { [weak self] in
                self?.dataTask?.resume()
            }
        } else {
            dataTask?.resume()
        }
    }

    /// Returns the first blocking effect (offline, failStatus, failError) from matched conditions.
    private func firstBlockingEffect() -> NetworkConditionEffect? {
        for condition in matchedConditions {
            switch condition.effect {
            case .offline, .failStatus, .failError:
                return condition.effect
            default:
                continue
            }
        }
        return nil
    }

    /// Apply a blocking effect — fail the request immediately without forwarding.
    private func applyBlockingEffect(_ effect: NetworkConditionEffect, url: String, method: String) {
        let endMs = PepperNetworkInterceptor.nowMs()

        // Build request info for recording
        let contentType = request.allHTTPHeaderFields?["Content-Type"]
        let bodyResult = PepperNetworkInterceptor.processBody(capturedRequestBody, contentType: contentType)
        let requestInfo = NetworkRequestInfo(
            url: url,
            method: method,
            headers: PepperNetworkInterceptor.extractRequestHeaders(request),
            body: bodyResult.body,
            bodyEncoding: bodyResult.encoding,
            bodyTruncated: bodyResult.truncated,
            originalBodySize: bodyResult.originalSize,
            timestampMs: startMs
        )

        switch effect {
        case .offline:
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "Simulated offline (Pepper network condition)"]
            )
            let transaction = NetworkTransaction(
                id: transactionId,
                request: requestInfo,
                response: nil,
                timing: NetworkTiming(startMs: startMs, endMs: endMs, durationMs: endMs - startMs),
                error: error.localizedDescription
            )
            PepperNetworkInterceptor.shared.record(transaction)
            PepperNetworkInterceptor.shared.decrementActiveRequests()
            client?.urlProtocol(self, didFailWithError: error)

        case .failStatus(let statusCode):
            // swiftlint:disable:next force_unwrapping — "about:blank" is a valid URL literal
            let responseUrl = request.url ?? URL(string: "about:blank")!
            guard
                let syntheticResponse = HTTPURLResponse(
                    url: responseUrl,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["X-Pepper-Simulated": "true"]
                )
            else { return }
            let body = Data("{\"error\":\"Simulated HTTP \(statusCode) (Pepper network condition)\"}".utf8)
            let respBody = PepperNetworkInterceptor.processBody(body, contentType: "application/json")
            let responseInfo = NetworkResponseInfo(
                statusCode: statusCode,
                headers: ["X-Pepper-Simulated": "true"],
                body: respBody.body,
                bodyEncoding: respBody.encoding,
                bodyTruncated: respBody.truncated,
                originalBodySize: respBody.originalSize,
                contentLength: Int64(body.count)
            )
            let transaction = NetworkTransaction(
                id: transactionId,
                request: requestInfo,
                response: responseInfo,
                timing: NetworkTiming(startMs: startMs, endMs: endMs, durationMs: endMs - startMs),
                error: nil
            )
            PepperNetworkInterceptor.shared.record(transaction)
            PepperNetworkInterceptor.shared.decrementActiveRequests()
            client?.urlProtocol(self, didReceive: syntheticResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)

        case .failError(let domain, let code):
            let error = NSError(
                domain: domain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Simulated error \(domain):\(code) (Pepper network condition)"]
            )
            let transaction = NetworkTransaction(
                id: transactionId,
                request: requestInfo,
                response: nil,
                timing: NetworkTiming(startMs: startMs, endMs: endMs, durationMs: endMs - startMs),
                error: error.localizedDescription
            )
            PepperNetworkInterceptor.shared.record(transaction)
            PepperNetworkInterceptor.shared.decrementActiveRequests()
            client?.urlProtocol(self, didFailWithError: error)

        default:
            break
        }
    }

    /// Apply a mock — return a synthetic response without forwarding the request.
    private func applyMock(_ mock: PepperNetworkMock, url: String, method: String) {
        let endMs = PepperNetworkInterceptor.nowMs()

        // Build request info for recording
        let contentType = request.allHTTPHeaderFields?["Content-Type"]
        let bodyResult = PepperNetworkInterceptor.processBody(capturedRequestBody, contentType: contentType)
        let requestInfo = NetworkRequestInfo(
            url: url,
            method: method,
            headers: PepperNetworkInterceptor.extractRequestHeaders(request),
            body: bodyResult.body,
            bodyEncoding: bodyResult.encoding,
            bodyTruncated: bodyResult.truncated,
            originalBodySize: bodyResult.originalSize,
            timestampMs: startMs
        )

        // Build synthetic response
        var responseHeaders = mock.headers
        responseHeaders["X-Pepper-Mocked"] = "true"
        // swiftlint:disable:next force_unwrapping — "about:blank" is a valid URL literal
        let responseUrl = request.url ?? URL(string: "about:blank")!
        guard
            let syntheticResponse = HTTPURLResponse(
                url: responseUrl,
                statusCode: mock.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: responseHeaders
            )
        else { return }

        let respContentType = mock.headers["Content-Type"] ?? "application/json"
        let respBody = PepperNetworkInterceptor.processBody(mock.body, contentType: respContentType)
        let responseInfo = NetworkResponseInfo(
            statusCode: mock.statusCode,
            headers: responseHeaders,
            body: respBody.body,
            bodyEncoding: respBody.encoding,
            bodyTruncated: respBody.truncated,
            originalBodySize: respBody.originalSize,
            contentLength: Int64(mock.body.count)
        )

        let transaction = NetworkTransaction(
            id: transactionId,
            request: requestInfo,
            response: responseInfo,
            timing: NetworkTiming(startMs: startMs, endMs: endMs, durationMs: endMs - startMs),
            error: nil
        )
        PepperNetworkInterceptor.shared.record(transaction)
        PepperNetworkInterceptor.shared.decrementActiveRequests()

        // Deliver the mocked response
        client?.urlProtocol(self, didReceive: syntheticResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mock.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
        forwardSession?.invalidateAndCancel()
        forwardSession = nil
    }
}

// MARK: - URLSessionDataDelegate

extension PepperNetworkProtocol: URLSessionDataDelegate {

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        httpResponse = response as? HTTPURLResponse

        // Detect SSE / streaming responses by Content-Type
        let contentType = httpResponse?.allHeaderFields["Content-Type"] as? String
        if PepperNetworkInterceptor.isStreamingContentType(contentType) {
            isStreaming = true
        }

        // If matched override or throttle, defer sending the response — we'll deliver after buffering
        if matchedOverride == nil && throttleBytesPerSecond == nil {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        // Record the initial streaming transaction now (before any chunks arrive)
        if isStreaming, !streamingRecorded {
            recordStreamingTransaction(contentType: contentType)
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)

        // For streaming responses, emit each chunk as a sub-event
        if isStreaming {
            PepperNetworkInterceptor.shared.recordStreamingChunk(
                transactionId: transactionId, data: data)
        }

        // If matched override or throttling, buffer only — don't stream to client yet
        if matchedOverride == nil && throttleBytesPerSecond == nil {
            client?.urlProtocol(self, didLoad: data)
        }
    }

    /// Record the initial streaming transaction when headers arrive.
    private func recordStreamingTransaction(contentType: String?) {
        streamingRecorded = true

        let reqContentType = request.allHTTPHeaderFields?["Content-Type"]
        let bodyResult = PepperNetworkInterceptor.processBody(capturedRequestBody, contentType: reqContentType)
        let requestInfo = NetworkRequestInfo(
            url: request.url?.absoluteString ?? "unknown",
            method: request.httpMethod ?? "GET",
            headers: PepperNetworkInterceptor.extractRequestHeaders(request),
            body: bodyResult.body,
            bodyEncoding: bodyResult.encoding,
            bodyTruncated: bodyResult.truncated,
            originalBodySize: bodyResult.originalSize,
            timestampMs: startMs
        )

        var responseInfo: NetworkResponseInfo?
        if let httpResponse = httpResponse {
            responseInfo = NetworkResponseInfo(
                statusCode: httpResponse.statusCode,
                headers: PepperNetworkInterceptor.extractHeaders(httpResponse),
                body: nil,
                bodyEncoding: nil,
                bodyTruncated: false,
                originalBodySize: 0,
                contentLength: Int64(httpResponse.expectedContentLength)
            )
        }

        var transaction = NetworkTransaction(
            id: transactionId,
            request: requestInfo,
            response: responseInfo,
            timing: NetworkTiming(startMs: startMs, endMs: nil, durationMs: nil),
            error: nil
        )
        transaction.streamContentType = contentType

        PepperNetworkInterceptor.shared.recordStreamingStart(transaction)
    }

    /// Lowest throttle rate from matched conditions, or nil if no throttle.
    private var throttleBytesPerSecond: Int? {
        let rates = matchedConditions.compactMap { condition -> Int? in
            if case .throttle(let bps) = condition.effect { return bps }
            return nil
        }
        return rates.min()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        PepperNetworkInterceptor.shared.decrementActiveRequests()

        // For streaming transactions, finalize instead of recording a new transaction
        if isStreaming && streamingRecorded {
            PepperNetworkInterceptor.shared.finalizeStreaming(
                transactionId: transactionId, error: error?.localizedDescription)

            if let error = error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
            forwardSession?.finishTasksAndInvalidate()
            return
        }

        let endMs = PepperNetworkInterceptor.nowMs()

        // Build request info — use body captured at startLoading (before stream was consumed)
        let contentType = request.allHTTPHeaderFields?["Content-Type"]
        let bodyResult = PepperNetworkInterceptor.processBody(capturedRequestBody, contentType: contentType)
        let requestInfo = NetworkRequestInfo(
            url: request.url?.absoluteString ?? "unknown",
            method: request.httpMethod ?? "GET",
            headers: PepperNetworkInterceptor.extractRequestHeaders(request),
            body: bodyResult.body,
            bodyEncoding: bodyResult.encoding,
            bodyTruncated: bodyResult.truncated,
            originalBodySize: bodyResult.originalSize,
            timestampMs: startMs
        )

        // Build response info — record the ORIGINAL response (before transform)
        var responseInfo: NetworkResponseInfo?
        if let httpResponse = httpResponse {
            let respContentType = httpResponse.allHeaderFields["Content-Type"] as? String
            let respBody = PepperNetworkInterceptor.processBody(responseData, contentType: respContentType)
            responseInfo = NetworkResponseInfo(
                statusCode: httpResponse.statusCode,
                headers: PepperNetworkInterceptor.extractHeaders(httpResponse),
                body: respBody.body,
                bodyEncoding: respBody.encoding,
                bodyTruncated: respBody.truncated,
                originalBodySize: respBody.originalSize,
                contentLength: Int64(httpResponse.expectedContentLength)
            )
        }

        // Build transaction
        let transaction = NetworkTransaction(
            id: transactionId,
            request: requestInfo,
            response: responseInfo,
            timing: NetworkTiming(
                startMs: startMs,
                endMs: endMs,
                durationMs: endMs - startMs
            ),
            error: error?.localizedDescription
        )

        // Record (original response data, before transform)
        PepperNetworkInterceptor.shared.record(transaction)

        // Complete the original request — apply transform if matched, then throttle if needed
        if let error = error {
            client?.urlProtocol(self, didFailWithError: error)
            forwardSession?.finishTasksAndInvalidate()
        } else if let override = matchedOverride, let httpResponse = httpResponse {
            // Apply the transform to the buffered response data
            let modifiedData = override.transform(responseData)

            // Create a new HTTPURLResponse with updated Content-Length
            let modifiedResponse = Self.responseWithUpdatedContentLength(httpResponse, newLength: modifiedData.count)
            client?.urlProtocol(self, didReceive: modifiedResponse, cacheStoragePolicy: .notAllowed)
            deliverData(modifiedData)
        } else if let bps = throttleBytesPerSecond, let httpResponse = httpResponse {
            // Throttle: send response header then drip-feed the buffered data
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            deliverThrottled(data: responseData, bytesPerSecond: bps)
        } else {
            client?.urlProtocolDidFinishLoading(self)
            forwardSession?.finishTasksAndInvalidate()
        }
    }

    // MARK: - Data Delivery Helpers

    /// Deliver data immediately and finish.
    private func deliverData(_ data: Data) {
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        forwardSession?.finishTasksAndInvalidate()
    }

    /// Deliver data in chunks to simulate bandwidth throttling.
    /// Sends `bytesPerSecond` bytes per second in 100ms intervals.
    private func deliverThrottled(data: Data, bytesPerSecond: Int) {
        let chunkInterval: TimeInterval = 0.1  // 100ms between chunks
        let chunkSize = max(1, bytesPerSecond / 10)  // bytes per 100ms

        DispatchQueue.global().async { [weak self] in
            var offset = 0
            while offset < data.count {
                guard let self = self else { return }
                let end = min(offset + chunkSize, data.count)
                let chunk = data.subdata(in: offset..<end)
                self.client?.urlProtocol(self, didLoad: chunk)
                offset = end
                if offset < data.count {
                    Thread.sleep(forTimeInterval: chunkInterval)
                }
            }
            if let self {
                self.client?.urlProtocolDidFinishLoading(self)
                self.forwardSession?.finishTasksAndInvalidate()
            }
        }
    }

    // MARK: - Response Helpers

    /// Construct a new HTTPURLResponse with an updated Content-Length header.
    /// HTTPURLResponse is immutable, so we must create a new instance.
    private static func responseWithUpdatedContentLength(_ original: HTTPURLResponse, newLength: Int) -> HTTPURLResponse
    {
        var headers = PepperNetworkInterceptor.extractHeaders(original)
        headers["Content-Length"] = String(newLength)
        return HTTPURLResponse(
            // swiftlint:disable:next force_unwrapping
            url: original.url ?? URL(string: "about:blank")!,
            statusCode: original.statusCode,
            httpVersion: nil,
            headerFields: headers
        ) ?? original
    }
}
