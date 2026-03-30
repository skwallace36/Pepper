import CoreData
import SwiftUI

/// Core Data CRUD screen accessible from the Misc tab.
/// Exercises `storage coredata`, `coredata entities`, `tap`, `input_text`, `swipe`, `scroll`.
struct CoreDataView: View {
    var body: some View {
        CoreDataListView()
            .environment(\.managedObjectContext, CoreDataStack.shared.viewContext)
    }
}

// MARK: - List View

private struct CoreDataListView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        fetchRequest: {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Item")
            request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
            return request
        }()
    )
    private var items: FetchedResults<NSManagedObject>

    @State private var showingAddSheet = false
    @State private var editingItem: NSManagedObject?
    @State private var sortKey: SortKey = .title
    @State private var filterText = ""

    enum SortKey: String, CaseIterable, Identifiable {
        case title, count, value, createdAt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: "Title"
            case .count: "Count"
            case .value: "Value"
            case .createdAt: "Date"
            }
        }
    }

    private var filteredItems: [NSManagedObject] {
        guard !filterText.isEmpty else { return Array(items) }
        return items.filter { obj in
            let title = obj.value(forKey: "title") as? String ?? ""
            return title.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sort & filter controls
            HStack {
                Picker("Sort", selection: $sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("coredata_sort_picker")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            TextField("Filter by title", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .accessibilityIdentifier("coredata_filter_field")

            Text("\(filteredItems.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .accessibilityIdentifier("coredata_item_count")

            List {
                ForEach(filteredItems, id: \.objectID) { item in
                    ItemRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { editingItem = item }
                        .accessibilityIdentifier("coredata_row_\(item.value(forKey: "title") as? String ?? "unknown")")
                }
                .onDelete(perform: deleteItems)
            }
            .listStyle(.plain)
            .accessibilityIdentifier("coredata_list")
        }
        .navigationTitle("Core Data")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("coredata_add_button")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            ItemFormSheet(mode: .add) { title, count, value in
                addItem(title: title, count: count, value: value)
            }
        }
        .sheet(item: $editingItem) { item in
            ItemFormSheet(mode: .edit(item)) { title, count, value in
                updateItem(item, title: title, count: count, value: value)
            }
        }
        .onChange(of: sortKey) { _, newKey in
            let ascending = newKey != .createdAt
            items.nsSortDescriptors = [NSSortDescriptor(key: newKey.rawValue, ascending: ascending)]
        }
    }

    // MARK: - CRUD

    private func addItem(title: String, count: Int32, value: Double) {
        guard let entity = NSEntityDescription.entity(forEntityName: "Item", in: viewContext) else { return }
        let obj = NSManagedObject(entity: entity, insertInto: viewContext)
        obj.setValue(title, forKey: "title")
        obj.setValue(count, forKey: "count")
        obj.setValue(value, forKey: "value")
        obj.setValue(Date(), forKey: "createdAt")
        save()
    }

    private func updateItem(_ item: NSManagedObject, title: String, count: Int32, value: Double) {
        item.setValue(title, forKey: "title")
        item.setValue(count, forKey: "count")
        item.setValue(value, forKey: "value")
        save()
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            viewContext.delete(filteredItems[index])
        }
        save()
    }

    private func save() {
        do {
            try viewContext.save()
        } catch {
            print("[PepperTest] Core Data save error: \(error)")
        }
    }
}

// MARK: - Item Row

private struct ItemRow: View {
    let item: NSManagedObject

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.value(forKey: "title") as? String ?? "Untitled")
                    .font(.body)
                    .accessibilityIdentifier("item_title")
                if let date = item.value(forKey: "createdAt") as? Date {
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("item_date")
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Count: \(item.value(forKey: "count") as? Int32 ?? 0)")
                    .font(.caption)
                    .accessibilityIdentifier("item_count")
                Text(String(format: "Value: %.2f", item.value(forKey: "value") as? Double ?? 0.0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("item_value")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add / Edit Sheet

private struct ItemFormSheet: View {
    enum Mode: Identifiable {
        case add
        case edit(NSManagedObject)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let obj): obj.objectID.uriRepresentation().absoluteString
            }
        }
    }

    let mode: Mode
    let onSave: (String, Int32, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var countText = ""
    @State private var valueText = ""

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item Details") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("coredata_form_title")
                    TextField("Count", text: $countText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("coredata_form_count")
                    TextField("Value", text: $valueText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("coredata_form_value")
                }
            }
            .navigationTitle(isEditing ? "Edit Item" : "New Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("coredata_form_cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, Int32(countText) ?? 0, Double(valueText) ?? 0.0)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("coredata_form_save")
                }
            }
            .onAppear {
                if case .edit(let item) = mode {
                    title = item.value(forKey: "title") as? String ?? ""
                    countText = "\(item.value(forKey: "count") as? Int32 ?? 0)"
                    valueText = "\(item.value(forKey: "value") as? Double ?? 0.0)"
                }
            }
        }
    }
}

// MARK: - NSManagedObject + Identifiable for sheet binding

extension NSManagedObject: @retroactive Identifiable {}
