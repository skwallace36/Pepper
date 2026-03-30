import SwiftUI

struct WebSocketView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ScrollView {
            VStack(spacing: 16) {
                // Connection status
                GroupBox("Connection") {
                    VStack(spacing: 8) {
                        HStack {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(state.wsStatus)
                                .font(.caption.monospacedDigit())
                                .accessibilityIdentifier("websocket_status_label")
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Button("Connect") {
                                state.wsConnect()
                            }
                            .accessibilityIdentifier("websocket_connect_button")

                            Button("Disconnect") {
                                state.wsDisconnect()
                            }
                            .accessibilityIdentifier("websocket_disconnect_button")
                        }
                    }
                }

                // Send message
                GroupBox("Send") {
                    VStack(spacing: 8) {
                        TextField("Message", text: $state.wsSendText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("websocket_message_input")

                        Button("Send") {
                            let text = state.wsSendText
                            guard !text.isEmpty else { return }
                            state.wsSend(text)
                            state.wsSendText = ""
                        }
                        .accessibilityIdentifier("websocket_send_button")
                    }
                }

                // Messages
                GroupBox("Messages (\(state.wsMessages.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        if state.wsMessages.isEmpty {
                            Text("No messages yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(state.wsMessages.enumerated()), id: \.offset) { index, msg in
                                Text(msg)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(msg.hasPrefix("→") ? .primary : .blue)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("websocket_message_\(index)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("websocket_messages_list")
                }
            }
            .padding()
        }
        .navigationTitle("WebSocket Client")
    }

    private var statusColor: Color {
        switch state.wsStatus {
        case "connected": .green
        case "connecting": .orange
        case "disconnected": .gray
        default: .red
        }
    }
}
