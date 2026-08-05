import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var history: History

    var body: some View {
        Group {
            if history.items.isEmpty {
                ContentUnavailableView(
                    "No transcripts yet",
                    systemImage: "clock",
                    description: Text("Dictated text will appear here.")
                )
            } else {
                List {
                    ForEach(history.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text)
                                .textSelection(.enabled)
                            HStack {
                                Text(item.date, style: .date)
                                Text(item.date, style: .time)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Copy") { copy(item.text) }
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    history.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(history.items.isEmpty)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
