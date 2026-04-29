import SwiftUI
import AppKit

struct WireLogView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedID: UUID?
    @State private var filter: Filter = .all
    @State private var search: String = ""
    @State private var autoScroll: Bool = true

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case sip = "SIP"
        case info = "Info"
        case errors = "Errors"
        var id: String { rawValue }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var filteredEntries: [WireLogEntry] {
        appState.wireLog.filter { entry in
            let kindMatch: Bool
            switch filter {
            case .all: kindMatch = true
            case .sip: kindMatch = entry.kind == .sip
            case .info: kindMatch = entry.kind == .info
            case .errors: kindMatch = entry.kind == .error
            }
            guard kindMatch else { return false }
            if search.isEmpty { return true }
            if entry.summary.localizedCaseInsensitiveContains(search) { return true }
            if let d = entry.detail, d.localizedCaseInsensitiveContains(search) { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .labelsHidden()

                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Spacer()

                Text("\(appState.wireLog.count) entries")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            HSplitView {
                logList
                    .frame(minWidth: 360)

                detailPane
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    appState.clearLog()
                    selectedID = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(appState.wireLog.isEmpty)
            }
        }
        .navigationTitle("Wire Log")
    }

    @ViewBuilder
    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, selection: $selectedID) { entry in
                HStack(spacing: 8) {
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .monospaced()
                        .foregroundStyle(.secondary)
                    Image(systemName: icon(for: entry))
                        .foregroundStyle(color(for: entry))
                    Text(entry.summary)
                        .lineLimit(1)
                }
                .tag(entry.id as UUID?)
            }
            .onChange(of: appState.wireLog.count) { _, _ in
                guard autoScroll, let id = filteredEntries.last?.id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(spacing: 0) {
            if let entry = selectedEntry {
                HStack {
                    Text(entry.summary)
                        .font(.headline)
                    Spacer()
                    Button {
                        let text = entry.detail ?? entry.summary
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(8)
                Divider()
                ScrollView {
                    Text(entry.detail ?? entry.summary)
                        .monospaced()
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
            } else {
                ContentUnavailableView(
                    "Select a message",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Pick an entry on the left to see its raw contents.")
                )
            }
        }
    }

    private var selectedEntry: WireLogEntry? {
        guard let id = selectedID else { return nil }
        return appState.wireLog.first { $0.id == id }
    }

    private func icon(for entry: WireLogEntry) -> String {
        switch entry.kind {
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        case .rtpStat: return "waveform"
        case .sip:
            return entry.direction == .sent ? "arrow.up.right" : "arrow.down.left"
        }
    }

    private func color(for entry: WireLogEntry) -> Color {
        switch entry.kind {
        case .error: return .red
        case .info: return .secondary
        case .rtpStat: return .purple
        case .sip:
            return entry.direction == .sent ? .blue : .green
        }
    }
}
