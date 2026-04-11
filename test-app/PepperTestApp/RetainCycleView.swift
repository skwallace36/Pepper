import SwiftUI

// MARK: - Retain Cycle Test Classes

/// Two NSObject subclasses that hold strong references to each other,
/// creating a deliberate retain cycle for Pepper's retain_cycles command to detect.
class RetainCycleA: NSObject {
    var other: RetainCycleB?
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    deinit { print("[PepperTest] RetainCycleA(\(label)) deallocated") }
}

class RetainCycleB: NSObject {
    var other: RetainCycleA?
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    deinit { print("[PepperTest] RetainCycleB(\(label)) deallocated") }
}

// MARK: - View

struct RetainCycleView: View {
    @State private var cycleCount: Int = 0
    @State private var leakedPairs: [(RetainCycleA, RetainCycleB)] = []

    var body: some View {
        VStack(spacing: 24) {
            GroupBox("Retain Cycle Factory") {
                VStack(spacing: 12) {
                    Text("Creates two NSObject subclasses with strong references to each other (A \u{2192} B \u{2192} A).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Create Retain Cycle") {
                        cycleCount += 1
                        let a = RetainCycleA(label: "pair-\(cycleCount)")
                        let b = RetainCycleB(label: "pair-\(cycleCount)")
                        a.other = b
                        b.other = a
                        // Hold references so the objects stay alive on the heap
                        leakedPairs.append((a, b))
                        print("[PepperTest] Created retain cycle pair-\(cycleCount): A \u{2192} B \u{2192} A")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("create_retain_cycle_button")

                    Text("Leaked pairs: \(cycleCount)")
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("retain_cycle_count")
                }
            }

            GroupBox("Heap Inspection") {
                VStack(spacing: 8) {
                    Text("Use Pepper commands to detect the cycles:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("heap class:RetainCycleA")
                        .font(.caption.monospaced())
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityIdentifier("retain_cycle_hint_heap")

                    Text("retain_cycles class:RetainCycleA")
                        .font(.caption.monospaced())
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityIdentifier("retain_cycle_hint_cmd")
                }
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Retain Cycles")
    }
}
