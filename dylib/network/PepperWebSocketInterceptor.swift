import Foundation
import os

/// Singleton capturing WebSocket frame-level traffic by swizzling URLSessionWebSocketTask.
/// Complements PepperNetworkInterceptor which only sees the HTTP upgrade request.
///
/// Usage:
///   PepperWebSocketInterceptor.shared.install()
///   // ... app sends/receives WebSocket messages ...
///   let frames = PepperWebSocketInterceptor.shared.recentFrames(limit: 50)
///   PepperWebSocketInterceptor.shared.uninstall()
final class PepperWebSocketInterceptor {
    static let shared = PepperWebSocketInterceptor()

    private var logger: Logger { PepperLogger.logger(category: "websocket") }
    private let queue = DispatchQueue(label: "com.pepper.control.websocket", attributes: .concurrent)

    /// Whether interception is active. Swizzled methods gate on this.
    private var isActive = false

    /// Whether swizzles have been applied (never reversed).
    private var swizzleApplied = false

    /// Thread-safe read of isActive.
    var isIntercepting: Bool {
        queue.sync { isActive }
    }

    /// Circular buffer of captured frames.
    private var frameBuffer: [WebSocketFrame] = []
    private(set) var bufferSize: Int = 500

    /// Total frames recorded (including evicted).
    private(set) var totalRecorded: Int = 0

    /// Total frames dropped due to buffer overflow.
    private(set) var totalDropped: Int = 0

    /// Active WebSocket connections keyed by task address.
    private var connections: [String: WebSocketConnection] = [:]

    /// Closed connections (kept for status reporting).
    private var closedConnections: [WebSocketConnection] = []
    private let maxClosedConnections = 50

    /// Maximum payload size before truncation (64KB — smaller than HTTP since frames are frequent).
    static let maxPayloadSize = 64 * 1024

    private init() {}

    // MARK: - Lifecycle

    /// Start intercepting WebSocket traffic.
    func install(bufferSize: Int? = nil) {
        queue.async(flags: .barrier) {
            if let size = bufferSize, size > 0 {
                self.bufferSize = size
            }

            if !self.swizzleApplied {
                self.applySwizzles()
                self.swizzleApplied = true
            }

            self.isActive = true
            self.logger.info("WebSocket interception started (buffer: \(self.bufferSize))")
        }
    }

    /// Stop intercepting (swizzles stay, isActive gates capture).
    func uninstall() {
        queue.async(flags: .barrier) {
            self.isActive = false
            self.logger.info("WebSocket interception stopped")
        }
    }

    // MARK: - Connection Tracking

    /// Register a new WebSocket connection. Called from swizzled task resume.
    func trackConnection(taskKey: String, url: String) {
        queue.async(flags: .barrier) {
            guard self.connections[taskKey] == nil else { return }
            let conn = WebSocketConnection(
                id: UUID().uuidString,
                url: url,
                startMs: PepperNetworkInterceptor.nowMs()
            )
            self.connections[taskKey] = conn
            self.logger.debug("WebSocket connected: \(url)")
        }
    }

    /// Mark a connection as closed.
    func closeConnection(taskKey: String, code: Int?, reason: String?) {
        queue.async(flags: .barrier) {
            guard var conn = self.connections.removeValue(forKey: taskKey) else { return }
            conn.endMs = PepperNetworkInterceptor.nowMs()
            conn.closeCode = code
            conn.closeReason = reason
            self.closedConnections.insert(conn, at: 0)
            if self.closedConnections.count > self.maxClosedConnections {
                self.closedConnections.removeLast()
            }
            self.logger.debug("WebSocket closed: \(conn.url) (code: \(code ?? -1))")
        }
    }

    /// Get or create connection ID for a task key.
    private func connectionId(for taskKey: String) -> String {
        // Called within barrier — safe to read connections
        connections[taskKey]?.id ?? taskKey
    }

    // MARK: - Frame Recording

    /// Record a captured WebSocket frame.
    func recordFrame(
        taskKey: String,
        direction: WebSocketFrameDirection,
        frameType: WebSocketFrameType,
        payload: Data?,
        error: Error?
    ) {
        queue.async(flags: .barrier) {
            guard self.isActive else { return }

            let connId = self.connectionId(for: taskKey)
            let url = self.connections[taskKey]?.url ?? "unknown"

            // Update connection stats
            if var conn = self.connections[taskKey] {
                let size = payload?.count ?? 0
                switch direction {
                case .sent:
                    conn.framesSent += 1
                    conn.bytesSent += size
                case .received:
                    conn.framesReceived += 1
                    conn.bytesReceived += size
                }
                self.connections[taskKey] = conn
            }

            // Process payload
            let processed = Self.processPayload(payload, frameType: frameType)

            let frame = WebSocketFrame(
                id: UUID().uuidString,
                connectionId: connId,
                direction: direction,
                frameType: frameType,
                payload: processed.payload,
                payloadEncoding: processed.encoding,
                payloadTruncated: processed.truncated,
                originalPayloadSize: processed.originalSize,
                timestampMs: PepperNetworkInterceptor.nowMs(),
                error: error?.localizedDescription
            )

            // Ring buffer
            if self.frameBuffer.count >= self.bufferSize {
                self.frameBuffer.removeFirst()
                self.totalDropped += 1
            }
            self.frameBuffer.append(frame)
            self.totalRecorded += 1

            // Flight recorder
            let arrow = direction == .sent ? "→" : "←"
            let typeLabel = frameType.rawValue
            let sizeStr = PepperNetworkInterceptor.formatBytes(processed.originalSize)
            let summary = "\(arrow) \(typeLabel) \(sizeStr) \(url)"
            PepperFlightRecorder.shared.record(type: .websocket, summary: summary, referenceId: frame.id)

            // Broadcast event
            let event = PepperEvent(
                event: "websocket_frame",
                data: frame.toDictionary()
            )
            DispatchQueue.main.async {
                PepperPlane.shared.broadcast(event)
            }
        }
    }

    // MARK: - Queries

    /// Get recent frames, optionally filtered.
    func recentFrames(limit: Int = 50, connectionFilter: String? = nil, directionFilter: String? = nil) -> [WebSocketFrame] {
        queue.sync {
            var results = frameBuffer
            if let connFilter = connectionFilter, !connFilter.isEmpty {
                // Filter by connection URL substring
                let connIds = connections.filter { $0.value.url.localizedCaseInsensitiveContains(connFilter) }.map(\.value.id)
                let closedIds = closedConnections.filter { $0.url.localizedCaseInsensitiveContains(connFilter) }.map(\.id)
                let allIds = Set(connIds + closedIds)
                results = results.filter { allIds.contains($0.connectionId) }
            }
            if let dir = directionFilter {
                if let direction = WebSocketFrameDirection(rawValue: dir) {
                    results = results.filter { $0.direction == direction }
                }
            }
            return Array(results.suffix(limit))
        }
    }

    /// Number of frames in the buffer.
    var frameCount: Int {
        queue.sync { frameBuffer.count }
    }

    /// Snapshot of active connections.
    var activeConnections: [WebSocketConnection] {
        queue.sync { Array(connections.values) }
    }

    /// Snapshot of recently closed connections.
    var recentClosedConnections: [WebSocketConnection] {
        queue.sync { closedConnections }
    }

    /// Clear the frame buffer.
    func clearBuffer() {
        queue.async(flags: .barrier) {
            self.frameBuffer.removeAll()
            self.logger.info("WebSocket frame buffer cleared")
        }
    }

    // MARK: - Payload Processing

    /// Process frame payload into (string, encoding, truncated, originalSize).
    static func processPayload(_ data: Data?, frameType: WebSocketFrameType) -> (
        payload: String?, encoding: String?, truncated: Bool, originalSize: Int
    ) {
        guard let data = data, !data.isEmpty else {
            return (nil, nil, false, 0)
        }

        let originalSize = data.count
        let truncated = data.count > maxPayloadSize
        let effectiveData = truncated ? data.prefix(maxPayloadSize) : data

        switch frameType {
        case .text:
            let text = String(data: effectiveData, encoding: .utf8)
                ?? String(data: effectiveData, encoding: .ascii)
            return (text, nil, truncated, originalSize)
        case .binary, .ping, .pong:
            return (effectiveData.base64EncodedString(), "base64", truncated, originalSize)
        }
    }

    // MARK: - Swizzle

    /// Swizzle URLSessionWebSocketTask send/receive methods to capture frame traffic.
    private func applySwizzles() {
        guard let wsTaskClass = NSClassFromString("__NSCFURLSessionWebSocketTask")
            ?? NSClassFromString("NSURLSessionWebSocketTask")
            ?? NSClassFromString("URLSessionWebSocketTask") else {
            // Try the public class directly
            let cls: AnyClass = URLSessionWebSocketTask.self
            swizzleClass(cls)
            return
        }
        swizzleClass(wsTaskClass)
    }

    private func swizzleClass(_ cls: AnyClass) {
        swizzleSend(cls)
        swizzleReceive(cls)
        swizzleCancel(cls)
        logger.info("Swizzled WebSocket task methods on \(NSStringFromClass(cls))")
    }

    // MARK: Send swizzle

    private func swizzleSend(_ cls: AnyClass) {
        // URLSessionWebSocketTask.send(_:completionHandler:)
        let selector = NSSelectorFromString("sendMessage:completionHandler:")
        guard let method = class_getInstanceMethod(cls, selector) else {
            logger.warning("Could not find WebSocket send method")
            return
        }

        let originalIMP = method_getImplementation(method)
        typealias SendFunc = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?) -> Void
        let original = unsafeBitCast(originalIMP, to: SendFunc.self)

        let block: @convention(block) (AnyObject, AnyObject, AnyObject?) -> Void = { [weak self] task, message, completion in
            if let self = self, self.isIntercepting, let wsTask = task as? URLSessionWebSocketTask {
                let taskKey = "\(ObjectIdentifier(wsTask))"

                // Track connection if new
                if let url = wsTask.currentRequest?.url?.absoluteString ?? wsTask.originalRequest?.url?.absoluteString {
                    self.trackConnection(taskKey: taskKey, url: url)
                }

                // Capture the frame
                let (frameType, payload) = Self.extractMessageContent(message)
                self.recordFrame(
                    taskKey: taskKey,
                    direction: .sent,
                    frameType: frameType,
                    payload: payload,
                    error: nil
                )
            }
            original(task, selector, message, completion)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: Receive swizzle

    private func swizzleReceive(_ cls: AnyClass) {
        // URLSessionWebSocketTask.receive(completionHandler:)
        let selector = NSSelectorFromString("receiveMessageWithCompletionHandler:")
        guard let method = class_getInstanceMethod(cls, selector) else {
            logger.warning("Could not find WebSocket receive method")
            return
        }

        let originalIMP = method_getImplementation(method)
        typealias ReceiveFunc = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let original = unsafeBitCast(originalIMP, to: ReceiveFunc.self)

        let block: @convention(block) (AnyObject, Any) -> Void = { [weak self] task, completionRaw in
            guard let self = self, self.isIntercepting, let wsTask = task as? URLSessionWebSocketTask else {
                original(task, selector, completionRaw as AnyObject)
                return
            }

            let taskKey = "\(ObjectIdentifier(wsTask))"

            // Track connection if new
            if let url = wsTask.currentRequest?.url?.absoluteString ?? wsTask.originalRequest?.url?.absoluteString {
                self.trackConnection(taskKey: taskKey, url: url)
            }

            // Wrap the completion handler to intercept the received message
            typealias CompletionType = @convention(block) (AnyObject?, AnyObject?) -> Void
            let originalCompletion = completionRaw as AnyObject

            let wrappedBlock: @convention(block) (AnyObject?, AnyObject?) -> Void = { [weak self] message, error in
                if let self = self, self.isIntercepting {
                    if let message = message {
                        let (frameType, payload) = Self.extractMessageContent(message)
                        self.recordFrame(
                            taskKey: taskKey,
                            direction: .received,
                            frameType: frameType,
                            payload: payload,
                            error: (error as? Error)?.localizedDescription.map { _ in error } as? Error
                        )
                    } else if let err = error as? Error {
                        self.recordFrame(
                            taskKey: taskKey,
                            direction: .received,
                            frameType: .text,
                            payload: nil,
                            error: err
                        )
                    }
                }

                // Call original completion
                let origBlock = unsafeBitCast(originalCompletion, to: CompletionType.self)
                origBlock(message, error)
            }

            let wrappedObj = wrappedBlock as AnyObject
            original(task, selector, wrappedObj)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: Cancel swizzle

    private func swizzleCancel(_ cls: AnyClass) {
        // URLSessionWebSocketTask.cancel(with:reason:)
        let selector = NSSelectorFromString("cancelWithCloseCode:reason:")
        guard let method = class_getInstanceMethod(cls, selector) else {
            logger.warning("Could not find WebSocket cancel method")
            return
        }

        let originalIMP = method_getImplementation(method)
        typealias CancelFunc = @convention(c) (AnyObject, Selector, Int, AnyObject?) -> Void
        let original = unsafeBitCast(originalIMP, to: CancelFunc.self)

        let block: @convention(block) (AnyObject, Int, AnyObject?) -> Void = { [weak self] task, code, reason in
            if let self = self, self.isIntercepting, let wsTask = task as? URLSessionWebSocketTask {
                let taskKey = "\(ObjectIdentifier(wsTask))"
                let reasonStr = (reason as? Data).flatMap { String(data: $0, encoding: .utf8) }
                self.closeConnection(taskKey: taskKey, code: code, reason: reasonStr)
            }
            original(task, selector, code, reason)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Helpers

    /// Extract frame type and payload from a URLSessionWebSocketTask.Message.
    static func extractMessageContent(_ message: AnyObject) -> (WebSocketFrameType, Data?) {
        // URLSessionWebSocketTask.Message is an enum: .string(String), .data(Data)
        // At the ObjC level, the message is bridged — try to extract via known patterns.

        // Try string extraction
        if message.responds(to: NSSelectorFromString("isKindOfClass:")) {
            if let str = message as? String {
                return (.text, str.data(using: .utf8))
            }
            if let data = message as? Data {
                return (.binary, data)
            }
        }

        // For URLSessionWebSocketTask.Message enum, use mirror to extract associated values
        let mirror = Mirror(reflecting: message)
        if let child = mirror.children.first {
            switch child.label {
            case "string":
                if let str = child.value as? String {
                    return (.text, str.data(using: .utf8))
                }
            case "data":
                if let data = child.value as? Data {
                    return (.binary, data)
                }
            default:
                break
            }
        }

        // Fallback: try NSString/NSData
        if let nsStr = message as? NSString {
            return (.text, (nsStr as String).data(using: .utf8))
        }
        if let nsData = message as? NSData {
            return (.binary, nsData as Data)
        }

        return (.binary, nil)
    }
}
