import SwiftUI

struct SheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showNestedSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("This is a sheet")
                    .font(.title2)
                    .accessibilityIdentifier("sheet_title")

                Button("Show Nested Sheet") {
                    showNestedSheet = true
                }
                .accessibilityIdentifier("nested_sheet_button")

                Button("Dismiss") {
                    dismiss()
                }
                .accessibilityIdentifier("sheet_dismiss_button")
            }
            .navigationTitle("Sheet")
            .sheet(isPresented: $showNestedSheet) {
                NestedSheetView()
            }
        }
    }
}

struct NestedSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Nested Sheet")
                .font(.title2)
                .accessibilityIdentifier("nested_sheet_title")

            Text("Two sheets deep")
                .accessibilityIdentifier("nested_sheet_label")

            Button("Dismiss") {
                dismiss()
            }
            .accessibilityIdentifier("nested_sheet_dismiss")
        }
    }
}
