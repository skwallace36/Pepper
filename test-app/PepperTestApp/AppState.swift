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

    // Timer
    var timerFired: Bool = false
    var timerCountdown: Int = 0

    // Network
    var lastHTTPStatus: Int? = nil
    var networkResponse: String = ""

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

    func fetchHTTP() {
        print("[PepperTest] Starting HTTP request")
        let url = URL(string: "https://httpbin.org/json")!
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
}

@Observable
final class NestedState {
    var innerValue: String = "nested-hello"
    var innerCount: Int = 42
}
