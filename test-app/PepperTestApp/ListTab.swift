import SwiftUI

struct ListTab: View {
    @Environment(AppState.self) private var state

    @State private var items: [ListItem] = (0..<30).map { i in
        ListItem(id: i, title: "Item \(i)", subtitle: "Subtitle for item \(i)")
    }
    @State private var searchText = ""

    var filteredItems: [ListItem] {
        if searchText.isEmpty { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredItems) { item in
                NavigationLink {
                    ListDetailView(item: item)
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.title)
                            .font(.body)
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("list_item_\(item.id)")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        items.removeAll { $0.id == item.id }
                        print("[PepperTest] Deleted item \(item.id)")
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        print("[PepperTest] Favorited item \(item.id)")
                    } label: {
                        Label("Favorite", systemImage: "star")
                    }
                    .tint(.yellow)
                }
            }
        }
        .navigationTitle("List")
        .searchable(text: $searchText, prompt: "Search items")
        .accessibilityIdentifier("items_list")
        .refreshable {
            print("[PepperTest] Pull to refresh triggered")
            try? await Task.sleep(for: .seconds(1))
            items = (0..<30).map { i in
                ListItem(id: i, title: "Item \(i)", subtitle: "Refreshed at \(Date().formatted(date: .omitted, time: .standard))")
            }
        }
    }
}

struct ListItem: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
}

struct ListDetailView: View {
    let item: ListItem

    var body: some View {
        VStack(spacing: 16) {
            Text(item.title)
                .font(.largeTitle)
                .accessibilityIdentifier("list_detail_title")

            Text(item.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("list_detail_subtitle")
        }
        .navigationTitle(item.title)
    }
}
