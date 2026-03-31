import SwiftUI
import Observation

@Observable
final class AppState {
    // Counters
    var tapCount: Int = 0
    var totalTaps: Int = 0

    // Toggles
    var notificationsEnabled: Bool = false
    var darkModeEnabled: Bool = false
    var airplaneMode: Bool = false

    // Text
    var textFieldValue: String = ""
    var textViewValue: String = "Editable text here"
    var searchQuery: String = ""

    // Selection
    var selectedSegment: Int = 0
    var sliderValue: Double = 0.5
    var selectedDate: Date = Date()
    var stepperValue: Int = 5

    // Timer (wait_for surface)
    var timerFired: Bool = false
    var timerCountdown: Int = 0

    // Network
    var lastHTTPStatus: Int? = nil
    var networkResponse: String = ""
    var networkElapsedMs: Int? = nil
    var networkStatusCode: String = ""
    var networkError: String = ""
    var networkBodyPreview: String = ""

    // WebSocket
    var wsStatus: String = "disconnected"
    var wsMessages: [String] = []
    var wsSendText: String = ""
    @ObservationIgnored private var wsTask: URLSessionWebSocketTask?
    @ObservationIgnored private var wsSession: URLSession?

    // NSTimer / CADisplayLink (for timers command)
    var repeatingTimerCount: Int = 0
    var displayLinkFrameCount: Int = 0

    @ObservationIgnored private var repeatingTimer: Timer?
    @ObservationIgnored private var displayLink: CADisplayLink?

    // NSNotificationCenter observers (for notifications command)
    var notificationReceivedCount: Int = 0

    @ObservationIgnored private var notificationObserver: NSObjectProtocol?
    static let testNotificationName = Notification.Name("PepperTestNotification")

    // Concurrency
    var concurrencyCompleted: Int = 0
    var concurrencyTotal: Int = 0
    var actorStatus: String = "idle"
    @ObservationIgnored let imageProcessor = ImageProcessor()
    @ObservationIgnored private var concurrencyTaskHandle: Task<Void, Never>?
    @ObservationIgnored private var actorTaskHandle: Task<Void, Never>?

    // Feature Flags (server-delivered)
    var serverFlagValue: String = "not fetched"

    // Nested object for vars_inspect depth testing
    var nested: NestedState = NestedState()

    func incrementTap() {
        tapCount += 1
        totalTaps += 1
        print("[PepperTest] Button tapped. Count: \(tapCount)")
    }

    func resetCount() {
        tapCount = 0
        print("[PepperTest] Counter reset")
    }

    func startTimer(seconds: Int = 3) {
        timerFired = false
        timerCountdown = seconds
        print("[PepperTest] Timer started: \(seconds)s")
        tick()
    }

    private func tick() {
        guard timerCountdown > 0 else {
            timerFired = true
            print("[PepperTest] Timer fired!")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.timerCountdown -= 1
            self.tick()
        }
    }

    // MARK: - NSTimer / CADisplayLink

    func startRepeatingTimer() {
        repeatingTimer?.invalidate()
        repeatingTimerCount = 0
        repeatingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.repeatingTimerCount += 1
            print("[PepperTest] NSTimer tick: \(self?.repeatingTimerCount ?? 0)")
        }
        print("[PepperTest] NSTimer started")
    }

    func stopRepeatingTimer() {
        repeatingTimer?.invalidate()
        repeatingTimer = nil
        print("[PepperTest] NSTimer stopped")
    }

    func startDisplayLink() {
        displayLink?.invalidate()
        displayLinkFrameCount = 0
        let dl = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
        print("[PepperTest] CADisplayLink started")
    }

    @objc private func displayLinkTick(_ sender: CADisplayLink) {
        displayLinkFrameCount += 1
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        print("[PepperTest] CADisplayLink stopped")
    }

    // MARK: - NSNotificationCenter

    func registerNotificationObserver() {
        guard notificationObserver == nil else {
            print("[PepperTest] Observer already registered")
            return
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: AppState.testNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notificationReceivedCount += 1
            print("[PepperTest] Notification received: \(self?.notificationReceivedCount ?? 0)")
        }
        print("[PepperTest] Notification observer registered")
    }

    func postTestNotification() {
        NotificationCenter.default.post(name: AppState.testNotificationName, object: nil)
        print("[PepperTest] Notification posted: PepperTestNotification")
    }

    func removeNotificationObserver() {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
            print("[PepperTest] Notification observer removed")
        }
    }

    // MARK: - Concurrency

    func spawnConcurrencyTasks() {
        concurrencyCompleted = 0
        concurrencyTotal = 5
        print("[PepperTest] Spawning 5 concurrent tasks")
        concurrencyTaskHandle = Task {
            await withTaskGroup(of: Void.self) { group in
                for i in 1...5 {
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(i) * 1_000_000_000)
                        await MainActor.run {
                            self.concurrencyCompleted += 1
                            print("[PepperTest] Task \(i) done (\(self.concurrencyCompleted)/5)")
                        }
                    }
                }
                await group.waitForAll()
            }
            print("[PepperTest] All spawned tasks finished")
        }
    }

    func startActorWork() {
        actorStatus = "running"
        print("[PepperTest] Starting actor work")
        actorTaskHandle = Task {
            await imageProcessor.reset()
            for i in 1...5 {
                guard !Task.isCancelled else { break }
                await imageProcessor.processImage(i)
                let count = await imageProcessor.processedCount
                await MainActor.run {
                    self.actorStatus = "processing \(count)/5"
                }
            }
            await MainActor.run {
                if self.actorStatus != "cancelled" {
                    self.actorStatus = "done"
                }
                print("[PepperTest] Actor work finished")
            }
        }
    }

    func cancelConcurrencyTasks() {
        concurrencyTaskHandle?.cancel()
        concurrencyTaskHandle = nil
        actorTaskHandle?.cancel()
        actorTaskHandle = nil
        actorStatus = "cancelled"
        print("[PepperTest] Tasks cancelled")
    }

    /// Fetches a server-delivered feature flag from a mock config endpoint.
    /// Checks `pepper.flags.overrides["server_feature"]` in UserDefaults first,
    /// so `flags set server_feature <value>` takes effect immediately without a network call.
    func fetchServerFlag() {
        if let overrides = UserDefaults.standard.dictionary(forKey: "pepper.flags.overrides"),
           let override = overrides["server_feature"] {
            serverFlagValue = String(describing: override)
            print("[PepperTest] Server flag (override): \(serverFlagValue)")
            return
        }
        guard let url = URL(string: "https://config.peppertest.example/flags") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = json["server_feature"] {
                    self?.serverFlagValue = String(describing: value)
                    print("[PepperTest] Server flag: \(self?.serverFlagValue ?? "")")
                } else {
                    self?.serverFlagValue = "fetch failed"
                    print("[PepperTest] Server flag fetch failed: \(error?.localizedDescription ?? "no data")")
                }
            }
        }.resume()
    }

    private func clearNetworkLabels() {
        networkElapsedMs = nil
        networkStatusCode = ""
        networkError = ""
        networkBodyPreview = ""
    }

    func fetchHTTP() {
        print("[PepperTest] Starting HTTP request")
        guard let url = URL(string: "https://httpbin.org/json") else { return }
        clearNetworkLabels()
        let start = Date()
        networkResponse = "Fetch: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                self?.networkElapsedMs = elapsed
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkStatusCode = "\(http.statusCode)"
                    self?.networkResponse = "Status: \(http.statusCode) in \(elapsed)ms"
                    print("[PepperTest] HTTP response: \(http.statusCode) \(elapsed)ms")
                } else if let error {
                    let nsError = error as NSError
                    self?.networkError = "\(nsError.domain) \(nsError.code)"
                    self?.networkResponse = "Error: \(error.localizedDescription)"
                    print("[PepperTest] HTTP error: \(error)")
                }
            }
        }.resume()
    }

    // MARK: - Network Simulation Surfaces

    /// Use with: network simulate latency / network simulate throttle
    func fetchSlowRequest() {
        let start = Date()
        print("[PepperTest] Slow request started (pair with: network simulate latency <ms>)")
        guard let url = URL(string: "https://httpbin.org/delay/1") else { return }
        clearNetworkLabels()
        networkResponse = "Slow: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                self?.networkElapsedMs = elapsed
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkStatusCode = "\(http.statusCode)"
                    self?.networkResponse = "Slow: \(http.statusCode) in \(elapsed)ms"
                    print("[PepperTest] Slow request: \(http.statusCode) \(elapsed)ms")
                } else if let error {
                    let nsError = error as NSError
                    self?.networkError = "\(nsError.domain) \(nsError.code)"
                    self?.networkResponse = "Slow error: \(error.localizedDescription)"
                    print("[PepperTest] Slow request error: \(error)")
                }
            }
        }.resume()
    }

    /// Use with: network simulate fail_status 500 / network simulate fail_error
    func fetchErrorRequest() {
        print("[PepperTest] Error-surface request started (pair with: network simulate fail_status 500)")
        guard let url = URL(string: "https://httpbin.org/get") else { return }
        clearNetworkLabels()
        let start = Date()
        networkResponse = "Error surface: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                self?.networkElapsedMs = elapsed
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkStatusCode = "\(http.statusCode)"
                    self?.networkResponse = "Error surface: \(http.statusCode)"
                    print("[PepperTest] Error surface response: \(http.statusCode)")
                } else if let error {
                    let nsError = error as NSError
                    self?.networkError = "\(nsError.domain) \(nsError.code)"
                    self?.networkResponse = "Fail error: [\(nsError.domain) \(nsError.code)]"
                    print("[PepperTest] Error surface error: \(nsError.domain) \(nsError.code)")
                }
            }
        }.resume()
    }

    /// Use with: network simulate offline
    func fetchOfflineRequest() {
        print("[PepperTest] Offline-surface request started (pair with: network simulate offline true)")
        guard let url = URL(string: "https://httpbin.org/get") else { return }
        clearNetworkLabels()
        let start = Date()
        networkResponse = "Offline: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                self?.networkElapsedMs = elapsed
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkStatusCode = "\(http.statusCode)"
                    self?.networkResponse = "Offline: \(http.statusCode) (no error injected)"
                    print("[PepperTest] Offline surface response: \(http.statusCode)")
                } else if let error {
                    let nsError = error as NSError
                    self?.networkError = "\(nsError.domain) \(nsError.code)"
                    self?.networkResponse = "Offline: [\(nsError.domain) \(nsError.code)]"
                    print("[PepperTest] Offline surface error: \(nsError.domain) \(nsError.code)")
                }
            }
        }.resume()
    }

    /// Use with: network mock url:https://pepper.test/mock body:'{"mocked":true}'
    func fetchMockRequest() {
        print("[PepperTest] Mock-surface request started (pair with: network mock url:https://pepper.test/mock)")
        guard let url = URL(string: "https://pepper.test/mock") else { return }
        clearNetworkLabels()
        let start = Date()
        networkResponse = "Mock: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                self?.networkElapsedMs = elapsed
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkStatusCode = "\(http.statusCode)"
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let preview = String(body.prefix(80))
                    self?.networkBodyPreview = preview
                    self?.networkResponse = "Mock: \(http.statusCode) — \(preview)"
                    print("[PepperTest] Mock response: \(http.statusCode) body=\(preview)")
                } else if let error {
                    let nsError = error as NSError
                    self?.networkError = "\(nsError.domain) \(nsError.code)"
                    self?.networkResponse = "Mock error: \(error.localizedDescription)"
                    print("[PepperTest] Mock error: \(error)")
                }
            }
        }.resume()
    }

    // MARK: - Background URLSession

    /// Fires a request via a background URLSessionConfiguration so Pepper's
    /// delegate-proxy interception can capture it.
    func fetchBackgroundRequest() {
        print("[PepperTest] Background request started")
        guard let url = URL(string: "https://httpbin.org/json") else { return }
        clearNetworkLabels()
        networkResponse = "Background: in flight…"

        let id = "com.peppertest.background.\(UUID().uuidString.prefix(8))"
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = false

        let delegate = BackgroundSessionDelegate { [weak self] statusCode, error in
            DispatchQueue.main.async {
                if let statusCode {
                    self?.lastHTTPStatus = statusCode
                    self?.networkStatusCode = "\(statusCode)"
                    self?.networkResponse = "Background: \(statusCode)"
                    print("[PepperTest] Background response: \(statusCode)")
                } else if let error {
                    let nsError = error as NSError
                    self?.networkError = "\(nsError.domain) \(nsError.code)"
                    self?.networkResponse = "Background error: \(error.localizedDescription)"
                    print("[PepperTest] Background error: \(error)")
                }
            }
        }

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        // Background sessions only support download tasks (not data tasks)
        session.downloadTask(with: url).resume()
    }

    // MARK: - WebSocket

    func wsConnect(urlString: String = "wss://echo.websocket.events") {
        wsDisconnect()
        guard let url = URL(string: urlString) else {
            wsStatus = "error: invalid URL"
            return
        }
        wsStatus = "connecting"
        wsMessages = []
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        wsSession = session
        wsTask = task
        task.resume()
        wsStatus = "connected"
        print("[PepperTest] WebSocket connected to \(urlString)")
        wsReceiveLoop()
    }

    func wsDisconnect() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        if wsStatus != "disconnected" {
            wsStatus = "disconnected"
            print("[PepperTest] WebSocket disconnected")
        }
    }

    func wsSend(_ text: String) {
        guard let task = wsTask else {
            wsStatus = "error: not connected"
            return
        }
        let message = URLSessionWebSocketTask.Message.string(text)
        task.send(message) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.wsStatus = "error: \(error.localizedDescription)"
                    print("[PepperTest] WebSocket send error: \(error)")
                } else {
                    self?.wsMessages.append("→ \(text)")
                    print("[PepperTest] WebSocket sent: \(text)")
                }
            }
        }
    }

    private func wsReceiveLoop() {
        wsTask?.receive { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self?.wsMessages.append("← \(text)")
                        print("[PepperTest] WebSocket received: \(text)")
                    case .data(let data):
                        self?.wsMessages.append("← [\(data.count) bytes]")
                        print("[PepperTest] WebSocket received \(data.count) bytes")
                    @unknown default:
                        break
                    }
                    self?.wsReceiveLoop()
                case .failure(let error):
                    self?.wsStatus = "disconnected"
                    print("[PepperTest] WebSocket receive error: \(error)")
                }
            }
        }
    }
}

// MARK: - Background Session Delegate

/// Minimal delegate for background URLSession download tasks.
/// Retains itself until the task completes so the session delegate isn't deallocated.
private final class BackgroundSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let completion: (_ statusCode: Int?, _ error: Error?) -> Void

    init(completion: @escaping (_ statusCode: Int?, _ error: Error?) -> Void) {
        self.completion = completion
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        completion(statusCode, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion(nil, error)
        }
    }
}

@Observable
final class NestedState {
    var innerValue: String = "nested-hello"
    var innerCount: Int = 42
}
