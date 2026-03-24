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

    // NSTimer / CADisplayLink (for timers command)
    var repeatingTimerCount: Int = 0
    var displayLinkFrameCount: Int = 0

    @ObservationIgnored private var repeatingTimer: Timer?
    @ObservationIgnored private var displayLink: CADisplayLink?

    // NSNotificationCenter observers (for notifications command)
    var notificationReceivedCount: Int = 0

    @ObservationIgnored private var notificationObserver: NSObjectProtocol?
    static let testNotificationName = Notification.Name("PepperTestNotification")

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

    func fetchHTTP() {
        print("[PepperTest] Starting HTTP request")
        guard let url = URL(string: "https://httpbin.org/json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkResponse = "Status: \(http.statusCode)"
                    print("[PepperTest] HTTP response: \(http.statusCode)")
                } else if let error {
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
        networkResponse = "Slow: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkResponse = "Slow: \(http.statusCode) in \(elapsed)ms"
                    print("[PepperTest] Slow request: \(http.statusCode) \(elapsed)ms")
                } else if let error {
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
        networkResponse = "Error surface: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkResponse = "Error surface: \(http.statusCode)"
                    print("[PepperTest] Error surface response: \(http.statusCode)")
                } else if let error {
                    let nsError = error as NSError
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
        networkResponse = "Offline: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    self?.networkResponse = "Offline: \(http.statusCode) (no error injected)"
                    print("[PepperTest] Offline surface response: \(http.statusCode)")
                } else if let error {
                    let nsError = error as NSError
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
        networkResponse = "Mock: in flight…"
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    self?.lastHTTPStatus = http.statusCode
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let preview = String(body.prefix(80))
                    self?.networkResponse = "Mock: \(http.statusCode) — \(preview)"
                    print("[PepperTest] Mock response: \(http.statusCode) body=\(preview)")
                } else if let error {
                    self?.networkResponse = "Mock error: \(error.localizedDescription)"
                    print("[PepperTest] Mock error: \(error)")
                }
            }
        }.resume()
    }
}

@Observable
final class NestedState {
    var innerValue: String = "nested-hello"
    var innerCount: Int = 42
}
