import SwiftUI

/// Fires known HTTP requests for cURL export verification.
/// Each button sends a request with predictable method, headers, and body
/// so `network log --format curl` output can be validated.
struct NetworkRequestsView: View {
    @State private var results: [RequestResult] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GroupBox("GET — query params + custom headers") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Send GET") {
                            sendGet()
                        }
                        .accessibilityIdentifier("curl_get_button")

                        resultView(for: "GET")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("POST — JSON body") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Send POST") {
                            sendPost()
                        }
                        .accessibilityIdentifier("curl_post_button")

                        resultView(for: "POST")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("PUT — auth header") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Send PUT") {
                            sendPut()
                        }
                        .accessibilityIdentifier("curl_put_button")

                        resultView(for: "PUT")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("All Requests") {
                    Button("Send All") {
                        sendGet()
                        sendPost()
                        sendPut()
                    }
                    .accessibilityIdentifier("curl_send_all_button")
                }
            }
            .padding()
        }
        .navigationTitle("Network Requests")
    }

    // MARK: - Requests

    private func sendGet() {
        guard var components = URLComponents(string: "https://httpbin.org/get") else { return }
        components.queryItems = [
            URLQueryItem(name: "search", value: "pepper"),
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "verbose", value: "true"),
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PepperTest/1.0", forHTTPHeaderField: "X-Client")
        request.setValue("req-abc-123", forHTTPHeaderField: "X-Request-ID")

        fire(request, label: "GET")
    }

    private func sendPost() {
        guard let url = URL(string: "https://httpbin.org/post") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "username": "pepper",
            "action": "test_curl_export",
            "count": 42,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        fire(request, label: "POST")
    }

    private func sendPut() {
        guard let url = URL(string: "https://httpbin.org/put") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer tok_pepper_test_12345", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "id": 7,
            "name": "updated-item",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        fire(request, label: "PUT")
    }

    // MARK: - Helpers

    private func fire(_ request: URLRequest, label: String) {
        setResult(label: label, status: "in flight…")
        print("[PepperTest] cURL surface: \(label) \(request.url?.absoluteString ?? "")")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    setResult(label: label, status: "\(http.statusCode) OK")
                    print("[PepperTest] cURL surface \(label): \(http.statusCode)")
                } else if let error {
                    setResult(label: label, status: "error: \(error.localizedDescription)")
                    print("[PepperTest] cURL surface \(label) error: \(error)")
                }
            }
        }.resume()
    }

    private func setResult(label: String, status: String) {
        if let index = results.firstIndex(where: { $0.label == label }) {
            results[index].status = status
        } else {
            results.append(RequestResult(label: label, status: status))
        }
    }

    @ViewBuilder
    private func resultView(for label: String) -> some View {
        if let result = results.first(where: { $0.label == label }) {
            Text(result.status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("curl_\(label.lowercased())_status")
        }
    }
}

private struct RequestResult: Identifiable {
    let id = UUID()
    let label: String
    var status: String
}
