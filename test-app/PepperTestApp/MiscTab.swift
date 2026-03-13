import SwiftUI
import WebKit
import MapKit
import os

struct MiscTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Layers (colors, shadows, gradients)
                GroupBox("Layers") {
                    VStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 60)
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                            .accessibilityIdentifier("gradient_box")

                        RoundedRectangle(cornerRadius: 12)
                            .fill(.orange)
                            .frame(height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.red, lineWidth: 2)
                            )
                            .accessibilityIdentifier("bordered_box")
                    }
                }

                // MARK: - Animation
                GroupBox("Animation") {
                    HStack(spacing: 20) {
                        PulsingDot()
                            .accessibilityIdentifier("pulsing_dot")

                        SpinnerView()
                            .accessibilityIdentifier("spinner")

                        Text("Animated views")
                    }
                }

                // MARK: - Timer (for wait_for)
                GroupBox("Timer") {
                    VStack(spacing: 8) {
                        Button("Start 3s Timer") {
                            state.startTimer(seconds: 3)
                        }
                        .accessibilityIdentifier("start_timer_button")

                        if state.timerCountdown > 0 {
                            Text("Countdown: \(state.timerCountdown)")
                                .accessibilityIdentifier("timer_countdown")
                        }

                        Text(state.timerFired ? "Timer: FIRED" : "Timer: waiting")
                            .accessibilityIdentifier("timer_status")
                    }
                }

                // MARK: - Network
                GroupBox("Network") {
                    VStack(spacing: 8) {
                        Button("Fetch HTTP") {
                            state.fetchHTTP()
                        }
                        .accessibilityIdentifier("fetch_button")

                        Text(state.networkResponse.isEmpty ? "No request yet" : state.networkResponse)
                            .accessibilityIdentifier("network_status")
                    }
                }

                // MARK: - Zoomable Image (for gesture/pinch)
                GroupBox("Pinch & Zoom") {
                    ZoomableImage()
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("zoomable_image")
                }

                // MARK: - Web View
                GroupBox("Web View") {
                    WebViewWrapper(url: URL(string: "https://example.com")!)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("web_view")
                }

                // MARK: - Map View
                GroupBox("Map") {
                    Map()
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("map_view")
                }

                // MARK: - UIKit Hosted
                GroupBox("UIKit") {
                    NavigationLink("UIKit Controls Screen") {
                        UIKitControlsWrapper()
                    }
                    .accessibilityIdentifier("uikit_link")
                }

                // MARK: - Context Menu
                GroupBox("Context Menu") {
                    Text("Long press me")
                        .padding()
                        .background(.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contextMenu {
                            Button("Copy") { print("[PepperTest] Context: Copy") }
                            Button("Share") { print("[PepperTest] Context: Share") }
                            Button(role: .destructive) { print("[PepperTest] Context: Delete") } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("context_menu_target")
                }
            }
            .padding()
        }
        .navigationTitle("Misc")
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 20, height: 20)
            .scaleEffect(isPulsing ? 1.5 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Spinner

struct SpinnerView: View {
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "arrow.trianglehead.2.counterclockwise")
            .font(.title2)
            .rotationEffect(.degrees(rotation))
            .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: rotation)
            .onAppear { rotation = 360 }
    }
}

// MARK: - Zoomable Image

struct ZoomableImage: UIViewRepresentable {
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: UIImage(systemName: "photo.artframe"))
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100
        scrollView.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }
    }
}

// MARK: - Web View

struct WebViewWrapper: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
