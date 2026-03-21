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

    /// If non-nil, this request matched an override — buffer response and apply transform.
    private var matchedOverride: PepperNetworkOverride?

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
              scheme == "http" || scheme == "https" else { return false }

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

        // Check if this request matches a response override
        let url = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"
        let bodyString: String? = capturedRequestBody.flatMap { String(data: $0, encoding: .utf8) }
        matchedOverride = PepperNetworkInterceptor.shared.matchingOverride(
            url: url, method: method, body: bodyString
        )

        // Mark the request so we don't intercept it again
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        // Create an ephemeral session without our protocol to avoid recursion
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = config.protocolClasses?.filter { $0 != PepperNetworkProtocol.self }
        forwardSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        dataTask = forwardSession?.dataTask(with: mutableRequest as URLRequest)
        dataTask?.resume()
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpResponse = response as? HTTPURLResponse
        // If matched, defer sending the response — we'll construct a new one after transform
        if matchedOverride == nil {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
        // If matched, buffer only — don't stream to client yet
        if matchedOverride == nil {
            client?.urlProtocol(self, didLoad: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        PepperNetworkInterceptor.shared.decrementActiveRequests()
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

        // Complete the original request — apply transform if matched
        if let error = error {
            client?.urlProtocol(self, didFailWithError: error)
        } else if let override = matchedOverride, let httpResponse = httpResponse {
            // Apply the transform to the buffered response data
            let modifiedData = override.transform(responseData)

            // Create a new HTTPURLResponse with updated Content-Length
            let modifiedResponse = Self.responseWithUpdatedContentLength(httpResponse, newLength: modifiedData.count)
            client?.urlProtocol(self, didReceive: modifiedResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: modifiedData)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }

        forwardSession?.finishTasksAndInvalidate()
    }

    // MARK: - Response Helpers

    /// Construct a new HTTPURLResponse with an updated Content-Length header.
    /// HTTPURLResponse is immutable, so we must create a new instance.
    private static func responseWithUpdatedContentLength(_ original: HTTPURLResponse, newLength: Int) -> HTTPURLResponse {
        var headers = PepperNetworkInterceptor.extractHeaders(original)
        headers["Content-Length"] = String(newLength)
        return HTTPURLResponse(
            url: original.url ?? URL(string: "about:blank")!,
            statusCode: original.statusCode,
            httpVersion: nil,
            headerFields: headers
        ) ?? original
    }
}
