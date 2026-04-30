import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case dialer = "Dialer"
    case inbound = "Inbound"
    case audio = "Audio Library"
    case scenarios = "Scenarios"
    case wireLog = "Wire Log"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dialer: return "phone.arrow.up.right"
        case .inbound: return "phone.arrow.down.left"
        case .audio: return "waveform"
        case .scenarios: return "list.bullet.rectangle"
        case .wireLog: return "doc.text.magnifyingglass"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: SidebarTab? = .dialer

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, id: \.self, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
            }
            .navigationTitle("SIP Client")
            .frame(minWidth: 180)
        } detail: {
            switch selection ?? .dialer {
            case .dialer: DialerView()
            case .inbound: InboundView()
            case .audio: AudioLibraryView()
            case .scenarios: ScenariosView()
            case .wireLog: WireLogView()
            }
        }
        .sheet(item: Binding(
            get: { appState.pendingImport },
            set: { appState.pendingImport = $0 }
        )) { pending in
            ImportProfileSheet(pending: pending)
                .environmentObject(appState)
        }
    }
}

/// Shown when the user double-clicks a `.sipcall` file. Lets them
/// rename the imported profile before adding it to their library.
struct ImportProfileSheet: View {
    @EnvironmentObject var appState: AppState
    let pending: PendingProfileImport

    @State private var name: String

    init(pending: PendingProfileImport) {
        self.pending = pending
        self._name = State(initialValue: pending.profile.name)
    }

    /// Existing profile that would be replaced — same UUID as the
    /// imported one. Non-nil ⇒ Import overwrites.
    private var existingProfile: DialerProfile? {
        appState.profile(id: pending.profile.id)
    }

    /// Existing profile that just happens to share the user's chosen
    /// name (but has a different UUID). Importing creates a duplicate
    /// name in the dropdown — annoying but not destructive.
    private var nameCollision: DialerProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return appState.profiles.first(where: {
            $0.id != pending.profile.id && $0.name == trimmed
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import profile?")
                .font(.headline)
            Text("From \(pending.sourceURL.lastPathComponent). Rename it before importing if you want.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Profile name")
                    .font(.caption)
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 2) {
                summaryRow("SIP host",   pending.profile.sipHost)
                summaryRow("To URI",     pending.profile.toURI)
                summaryRow("Transport",  pending.profile.transportKind.displayName)
                summaryRow("SRTP",       pending.profile.useSRTP ? "Enabled" : "Disabled")
                summaryRow("Codecs",     pending.profile.codecs.map(\.rtpmapName)
                                                                .joined(separator: ", "))
                if !pending.profile.customHeaders.isEmpty {
                    summaryRow("Custom headers",
                               "\(pending.profile.customHeaders.count) header(s)")
                }
            }
            .font(.caption)

            // Warn about same-identity overwrite.
            if let existing = existingProfile {
                collisionBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    message: "This will replace the existing profile “\(existing.name)”."
                )
            } else if let collision = nameCollision {
                // Different UUID, same name — non-destructive but worth flagging.
                collisionBanner(
                    icon: "info.circle.fill",
                    color: .blue,
                    message: "A profile named “\(collision.name)” already exists. Importing will add a second one."
                )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.cancelPendingImport()
                }
                .keyboardShortcut(.cancelAction)

                // When the imported UUID collides with one we already
                // have, give the user three choices instead of two:
                // cancel, take it as a separate copy, or overwrite.
                if existingProfile != nil {
                    Button("New Copy") {
                        importAsNewCopy()
                    }
                }

                primaryActionButton
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let label = existingProfile != nil ? "Replace" : "Import"
        Button(label) {
            var p = pending.profile
            p.name = trimmed
            appState.confirmPendingImport(profile: p)
        }
        .buttonStyle(.borderedProminent)
        .tint(existingProfile != nil ? .red : .accentColor)
        .keyboardShortcut(.defaultAction)
        .disabled(trimmed.isEmpty)
    }

    /// Import while regenerating the UUID so the new entry doesn't
    /// shadow the existing same-identity profile.
    private func importAsNewCopy() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var p = pending.profile.withFreshID()
        p.name = trimmed
        appState.confirmPendingImport(profile: p)
    }

    @ViewBuilder
    private func collisionBanner(icon: String, color: Color, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.12))
        )
    }

    @ViewBuilder
    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .monospaced()
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
