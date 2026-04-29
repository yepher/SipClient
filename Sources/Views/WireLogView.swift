import SwiftUI

struct WireLogView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedID: UUID?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HSplitView {
            List(appState.wireLog, selection: $selectedID) { entry in
                HStack(spacing: 8) {
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .monospaced()
                        .foregroundStyle(.secondary)
                    Image(systemName: entry.direction == .sent ? "arrow.up.right" : "arrow.down.left")
                        .foregroundStyle(entry.direction == .sent ? .blue : .green)
                    Text(entry.summary)
                        .lineLimit(1)
                }
                .tag(entry.id as UUID?)
            }
            .frame(minWidth: 320)

            ScrollView {
                if let detail = selectedDetail {
                    Text(detail)
                        .monospaced()
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                } else {
                    Text("Select a message to see its raw contents.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    appState.wireLog.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(appState.wireLog.isEmpty)
            }
        }
        .navigationTitle("Wire Log")
    }

    private var selectedDetail: String? {
        guard let id = selectedID,
              let entry = appState.wireLog.first(where: { $0.id == id })
        else { return nil }
        return entry.detail ?? entry.summary
    }
}
