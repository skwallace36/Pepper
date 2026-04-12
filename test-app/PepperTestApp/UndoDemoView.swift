import SwiftUI

@Observable
final class UndoDemoModel {
    var items: [String] = ["Item 1", "Item 2", "Item 3"]
    var nextIndex: Int = 4
    let undoManager = UndoManager()

    func addItem() {
        let name = "Item \(nextIndex)"
        let index = items.count
        items.append(name)
        nextIndex += 1

        undoManager.registerUndo(withTarget: self) { model in
            model.removeItem(at: index)
        }
        undoManager.setActionName("Add \(name)")
        print("[PepperTest] Undo: added \(name)")
    }

    func removeItem(at index: Int) {
        guard index < items.count else { return }
        let name = items[index]
        items.remove(at: index)

        undoManager.registerUndo(withTarget: self) { model in
            model.insertItem(name, at: index)
        }
        undoManager.setActionName("Delete \(name)")
        print("[PepperTest] Undo: removed \(name)")
    }

    func insertItem(_ name: String, at index: Int) {
        let safeIndex = min(index, items.count)
        items.insert(name, at: safeIndex)

        undoManager.registerUndo(withTarget: self) { model in
            model.removeItem(at: safeIndex)
        }
        undoManager.setActionName("Add \(name)")
        print("[PepperTest] Undo: inserted \(name) at \(safeIndex)")
    }

    func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            removeItem(at: index)
        }
    }

    var statusText: String {
        var parts: [String] = []
        parts.append("canUndo:\(undoManager.canUndo)")
        parts.append("canRedo:\(undoManager.canRedo)")
        let undoName = undoManager.undoActionName
        let redoName = undoManager.redoActionName
        if !undoName.isEmpty { parts.append("undo:\"\(undoName)\"") }
        if !redoName.isEmpty { parts.append("redo:\"\(redoName)\"") }
        return parts.joined(separator: "  ")
    }
}

struct UndoDemoView: View {
    @State private var model = UndoDemoModel()

    var body: some View {
        VStack(spacing: 0) {
            // Status label
            Text(model.statusText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .accessibilityIdentifier("undo_status_label")

            // Item list
            List {
                ForEach(model.items, id: \.self) { item in
                    Text(item)
                        .accessibilityIdentifier("undo_item_\(item.lowercased().replacingOccurrences(of: " ", with: "_"))")
                }
                .onDelete(perform: model.deleteItems)
            }
            .accessibilityIdentifier("undo_item_list")

            // Controls
            HStack(spacing: 12) {
                Button("Add Item") {
                    model.addItem()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("undo_add_button")

                Button("Undo") {
                    model.undoManager.undo()
                }
                .buttonStyle(.bordered)
                .disabled(!model.undoManager.canUndo)
                .accessibilityIdentifier("undo_undo_button")

                Button("Redo") {
                    model.undoManager.redo()
                }
                .buttonStyle(.bordered)
                .disabled(!model.undoManager.canRedo)
                .accessibilityIdentifier("undo_redo_button")
            }
            .padding()
        }
        .navigationTitle("Undo Demo")
    }
}
