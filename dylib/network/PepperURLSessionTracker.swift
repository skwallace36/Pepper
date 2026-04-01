import Foundation
import os

/// Tracks all live URLSession instances by swizzling the session factory method.
/// Provides `getAllActiveTasks()` to snapshot in-flight tasks across every session.
final class PepperURLSessionTracker {
    static let shared = PepperURLSessionTracker()

    private var logger: Logger { PepperLogger.logger(category: "session-tracker") }
    private let lock = NSLock()

    /// Weak references to every URLSession created while tracking is installed.
    private var sessions = NSHashTable<URLSession>.weakObjects()

    /// Whether the swizzle has been applied (one-shot, never reversed).
    private var swizzleApplied = false

    private init() {}

    // MARK: - Lifecycle

    /// Apply the swizzle (idempotent). Call during `network start`.
    func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !swizzleApplied else { return }
        applySwizzle()
        // Always track URLSession.shared
        sessions.add(URLSession.shared)
        swizzleApplied = true
        logger.info("URLSession tracker installed")
    }

    /// Number of live (non-deallocated) tracked sessions.
    var trackedSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.allObjects.count
    }

    // MARK: - Task Snapshot

    /// Collect all tasks from every tracked session.
    /// Uses `getAllTasks(completionHandler:)` (public Foundation API).
    /// Returns within `timeout` seconds or returns what it has.
    func getAllActiveTasks(timeout: TimeInterval = 3) -> [URLSessionTaskSnapshot] {
        lock.lock()
        let liveSessions = sessions.allObjects
        lock.unlock()

        guard !liveSessions.isEmpty else { return [] }

        var allSnapshots: [URLSessionTaskSnapshot] = []
        let group = DispatchGroup()
        let collector = NSLock()

        for session in liveSessions {
            group.enter()
            session.getAllTasks { tasks in
                let snapshots = tasks.map { URLSessionTaskSnapshot(task: $0, session: session) }
                collector.lock()
                allSnapshots.append(contentsOf: snapshots)
                collector.unlock()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + timeout)
        if result == .timedOut {
            PepperLogger.logger(category: "session-tracker")
                .warning("Timed out collecting tasks from \(liveSessions.count) sessions")
        }

        return allSnapshots.sorted { $0.taskIdentifier < $1.taskIdentifier }
    }

    // MARK: - Swizzle

    /// Swizzle +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]
    /// to register every new session.
    private func applySwizzle() {
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
                let session = original(selfCls, sel, config, delegate, queue)
                PepperURLSessionTracker.shared.track(session)
                return session
            }

        method_setImplementation(method, imp_implementationWithBlock(block))
        logger.info("Swizzled URLSession factory for session tracking")
    }

    private func track(_ session: URLSession) {
        lock.lock()
        sessions.add(session)
        lock.unlock()
    }
}

// MARK: - Task Snapshot

/// Serializable snapshot of a single URLSessionTask.
struct URLSessionTaskSnapshot {
    let taskIdentifier: Int
    let state: URLSessionTask.State
    let priority: Float
    let countOfBytesReceived: Int64
    let countOfBytesSent: Int64
    let countOfBytesExpectedToReceive: Int64
    let countOfBytesExpectedToSend: Int64
    let originalRequestURL: String?
    let originalRequestMethod: String?
    let currentRequestURL: String?
    let responseStatusCode: Int?
    let responseMIME: String?
    let error: String?
    let taskDescription: String?
    let taskType: String
    let sessionDescription: String?

    init(task: URLSessionTask, session: URLSession) {
        self.taskIdentifier = task.taskIdentifier
        self.state = task.state
        self.priority = task.priority
        self.countOfBytesReceived = task.countOfBytesReceived
        self.countOfBytesSent = task.countOfBytesSent
        self.countOfBytesExpectedToReceive = task.countOfBytesExpectedToReceive
        self.countOfBytesExpectedToSend = task.countOfBytesExpectedToSend
        self.originalRequestURL = task.originalRequest?.url?.absoluteString
        self.originalRequestMethod = task.originalRequest?.httpMethod
        self.currentRequestURL = task.currentRequest?.url?.absoluteString
        self.taskDescription = task.taskDescription
        self.error = task.error?.localizedDescription
        self.sessionDescription = session.sessionDescription ?? session.configuration.identifier

        if let http = task.response as? HTTPURLResponse {
            self.responseStatusCode = http.statusCode
            self.responseMIME = http.mimeType
        } else {
            self.responseStatusCode = nil
            self.responseMIME = nil
        }

        switch task {
        case is URLSessionDataTask: self.taskType = "data"
        case is URLSessionUploadTask: self.taskType = "upload"
        case is URLSessionDownloadTask: self.taskType = "download"
        case is URLSessionStreamTask: self.taskType = "stream"
        case is URLSessionWebSocketTask: self.taskType = "websocket"
        default: self.taskType = "unknown"
        }
    }

    /// State name matching Apple docs.
    var stateName: String {
        switch state {
        case .running: return "running"
        case .suspended: return "suspended"
        case .canceling: return "canceling"
        case .completed: return "completed"
        @unknown default: return "unknown"
        }
    }

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "task_id": AnyCodable(taskIdentifier),
            "type": AnyCodable(taskType),
            "state": AnyCodable(stateName),
            "priority": AnyCodable(priority),
            "bytes_received": AnyCodable(countOfBytesReceived),
            "bytes_sent": AnyCodable(countOfBytesSent),
        ]
        if countOfBytesExpectedToReceive != NSURLSessionTransferSizeUnknown {
            dict["bytes_expected_to_receive"] = AnyCodable(countOfBytesExpectedToReceive)
        }
        if countOfBytesExpectedToSend != NSURLSessionTransferSizeUnknown {
            dict["bytes_expected_to_send"] = AnyCodable(countOfBytesExpectedToSend)
        }
        if let url = originalRequestURL {
            dict["url"] = AnyCodable(url)
        }
        if let method = originalRequestMethod {
            dict["method"] = AnyCodable(method)
        }
        if let url = currentRequestURL, url != originalRequestURL {
            dict["current_url"] = AnyCodable(url)
        }
        if let status = responseStatusCode {
            dict["response_status"] = AnyCodable(status)
        }
        if let mime = responseMIME {
            dict["response_mime"] = AnyCodable(mime)
        }
        if let err = error {
            dict["error"] = AnyCodable(err)
        }
        if let desc = taskDescription {
            dict["description"] = AnyCodable(desc)
        }
        if let sess = sessionDescription {
            dict["session"] = AnyCodable(sess)
        }

        // Progress percentage when expected size is known
        if countOfBytesExpectedToReceive > 0, countOfBytesExpectedToReceive != NSURLSessionTransferSizeUnknown {
            let pct = Double(countOfBytesReceived) / Double(countOfBytesExpectedToReceive) * 100
            dict["progress_pct"] = AnyCodable(Int(pct))
        }

        return dict
    }
}
