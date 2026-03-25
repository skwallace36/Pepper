import SwiftUI

struct UndoDemoView: View {
    @State private var items: [String] = ["Item 1", "Item 2", "Item 3"]
    @State private var nextIndex: Int = 4
    @State private var statusText: String = "Ready"

    private let undoManager = UndoManager()

    var body: some View {
        VStack(spacing: 0) {
            // Status label
            Text(statusText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .accessibilityIdentifier("undo_status_label")

            // Item list
            List {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .accessibilityIdentifier("undo_item_\(item.lowercased().replacingOccurrences(of: " ", with: "_"))")
                }
                .onDelete(perform: deleteItems)
            }
            .accessibilityIdentifier("undo_item_list")

            // Controls
            HStack(spacing: 12) {
                Button("Add Item") {
                    addItem()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("undo_add_button")

                Button("Undo") {
                    undoManager.undo()
                    refreshStatus()
                }
                .buttonStyle(.bordered)
                .disabled(!undoManager.canUndo)
                .accessibilityIdentifier("undo_undo_button")

                Button("Redo") {
                    undoManager.redo()
                    refreshStatus()
                }
                .buttonStyle(.bordered)
                .disabled(!undoManager.canRedo)
                .accessibilityIdentifier("undo_redo_button")
            }
            .padding()
        }
        .navigationTitle("Undo Demo")
        .onAppear { refreshStatus() }
    }

    // MARK: - Actions

    private func addItem() {
        let name = "Item \(nextIndex)"
        let index = items.count
        items.append(name)
        nextIndex += 1

        undoManager.registerUndo(withTarget: UndoTarget(items: $items, nextIndex: $nextIndex)) { target in
            target.removeItem(at: index, undoManager: undoManager)
        }
        undoManager.setActionName("Add \(name)")

        print("[PepperTest] Undo: added \(name)")
        refreshStatus()
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            let name = items[index]
            items.remove(at: index)

            undoManager.registerUndo(withTarget: UndoTarget(items: $items, nextIndex: $nextIndex)) { target in
                target.insertItem(name, at: index, undoManager: undoManager)
            }
            undoManager.setActionName("Delete \(name)")

            print("[PepperTest] Undo: deleted \(name)")
        }
        refreshStatus()
    }

    private func refreshStatus() {
        let canUndo = undoManager.canUndo
        let canRedo = undoManager.canRedo
        let undoName = undoManager.undoActionName
        let redoName = undoManager.redoActionName
        var parts: [String] = []
        parts.append("canUndo:\(canUndo)")
        parts.append("canRedo:\(canRedo)")
        if !undoName.isEmpty { parts.append("undo:\"\(undoName)\"") }
        if !redoName.isEmpty { parts.append("redo:\"\(redoName)\"") }
        statusText = parts.joined(separator: "  ")
    }
}

// MARK: - UndoTarget (NSObject required by registerUndo)

private final class UndoTarget: NSObject {
    private let items: Binding<[String]>
    private let nextIndex: Binding<Int>

    init(items: Binding<[String]>, nextIndex: Binding<Int>) {
        self.items = items
        self.nextIndex = nextIndex
    }

    func removeItem(at index: Int, undoManager: UndoManager) {
        guard index < items.wrappedValue.count else { return }
        let name = items.wrappedValue[index]
        items.wrappedValue.remove(at: index)
        undoManager.registerUndo(withTarget: self) { target in
            target.insertItem(name, at: index, undoManager: undoManager)
        }
        undoManager.setActionName("Add \(name)")
        print("[PepperTest] Undo: removed \(name)")
    }

    func insertItem(_ name: String, at index: Int, undoManager: UndoManager) {
        let safeIndex = min(index, items.wrappedValue.count)
        items.wrappedValue.insert(name, at: safeIndex)
        undoManager.registerUndo(withTarget: self) { target in
            target.removeItem(at: safeIndex, undoManager: undoManager)
        }
        undoManager.setActionName("Delete \(name)")
        print("[PepperTest] Undo: inserted \(name) at \(safeIndex)")
    }
}
