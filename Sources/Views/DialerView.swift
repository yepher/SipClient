import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DialerView: View {
    @EnvironmentObject var appState: AppState

    /// Working copy of the selected profile. Edits don't persist until
    /// "Save" is pressed.
    @State private var draft: DialerProfile = DialerProfile(name: "New Profile")
    @State private var hasUnsavedChanges: Bool = false

    /// Auth password is intentionally only kept in memory.
    @State private var authPassword: String = ""

    @State private var showSaveAsSheet: Bool = false
    @State private var saveAsName: String = ""
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            InCallView(
                onPlaceCall: {
                    let cfg = draft.callConfig(authPassword: authPassword)
                    appState.placeCall(config: cfg)
                },
                placeCallDisabled: draft.sipHost.isEmpty || draft.toURI.isEmpty
            )
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Form {
                profileSection
                targetSection
                identitySection
                authSection
                natSection
                localSection
                codecSection
                customHeadersSection
            }
            .formStyle(.grouped)
            .padding()
        }
        .navigationTitle("Dialer")
        .onAppear { syncFromSelection() }
        .onChange(of: appState.selectedProfileID) { _, _ in syncFromSelection() }
        .sheet(isPresented: $showSaveAsSheet) {
            saveAsSheet
        }
        .alert("Delete profile “\(draft.name)”?",
               isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                appState.deleteProfile(id: draft.id)
                syncFromSelection()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var profileSection: some View {
        Section("Profile") {
            HStack {
                Picker("", selection: Binding(
                    get: { appState.selectedProfileID },
                    set: { appState.selectProfile($0) }
                )) {
                    if appState.profiles.isEmpty {
                        Text("No profiles").tag(UUID?.none)
                    } else {
                        ForEach(appState.profiles) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)

                if hasUnsavedChanges {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button {
                    saveAsName = draft.name + " copy"
                    showSaveAsSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                }

                Button {
                    appState.upsertProfile(draft)
                    hasUnsavedChanges = false
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                }
                .disabled(!hasUnsavedChanges || appState.profiles.firstIndex(where: { $0.id == draft.id }) == nil)

                Button {
                    exportProfile()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export current profile to a .sipcall file")

                Button {
                    importProfile()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import a .sipcall file")

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(appState.profile(id: appState.selectedProfileID) == nil)
            }
            .buttonStyle(.bordered)

            TextField("Profile name", text: bind(\.name))
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        Section("Target") {
            HStack {
                Text("Transport")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: Binding(
                    get: { draft.transportKind },
                    set: { newValue in
                        let oldDefault = draft.transportKind.defaultPort
                        draft.transportKind = newValue
                        // Bump the port to the new transport's default
                        // when the user is on the previous default.
                        if draft.sipPort == oldDefault {
                            draft.sipPort = newValue.defaultPort
                        }
                        hasUnsavedChanges = true
                    }
                )) {
                    ForEach(SIPTransportKind.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            if draft.transportKind == .tls {
                Toggle("Allow self-signed TLS certificate", isOn: bind(\.allowSelfSignedTLS))
            }
            Toggle("Use SRTP (SDES, AES_CM_128_HMAC_SHA1_80)",
                   isOn: bind(\.useSRTP))
            TextField("SIP server host", text: bind(\.sipHost),
                      prompt: Text("sip.example.com"))
            TextField("SIP port",
                      text: portBind(\.sipPort, default: draft.transportKind.defaultPort))
            TextField("To URI", text: bind(\.toURI),
                      prompt: Text("sip:+15551234567@sip.example.com"))
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        Section("Caller identity") {
            TextField("From user", text: bind(\.fromUser))
            TextField("From display name", text: bind(\.fromDisplay))
        }
    }

    @ViewBuilder
    private var authSection: some View {
        Section("Auth (optional, password not saved)") {
            TextField("Auth username (defaults to From user)",
                      text: bind(\.authUser))
            SecureField("Auth password", text: $authPassword)
        }
    }

    @ViewBuilder
    private var natSection: some View {
        Section("NAT") {
            Toggle("Use STUN", isOn: bind(\.useSTUN))
            TextField("STUN server (blank = default)",
                      text: bind(\.stunServer))
                .disabled(!draft.useSTUN)
        }
    }

    @ViewBuilder
    private var localSection: some View {
        Section("Local") {
            TextField("Local SIP port",
                      text: portBind(\.localSIPPort, default: 5060))
            TextField("Local RTP port",
                      text: portBind(\.localRTPPort, default: 10000))
        }
    }

    @ViewBuilder
    private var codecSection: some View {
        Section("Codecs (offered in SDP, peer picks one)") {
            ForEach(CodecKind.allCases) { kind in
                Toggle(kind.displayName, isOn: codecToggleBinding(for: kind))
            }
            if draft.codecs.isEmpty {
                Text("Defaults to PCMU + PCMA when none are selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Toggle binding that adds/removes a codec from `draft.codecs`,
    /// preserving CodecKind.allCases as the canonical preference order.
    private func codecToggleBinding(for kind: CodecKind) -> Binding<Bool> {
        Binding<Bool>(
            get: { draft.codecs.contains(kind) },
            set: { isOn in
                var set = Set(draft.codecs)
                if isOn { set.insert(kind) } else { set.remove(kind) }
                draft.codecs = CodecKind.allCases.filter { set.contains($0) }
                hasUnsavedChanges = true
            }
        )
    }

    @ViewBuilder
    private var customHeadersSection: some View {
        Section("Custom SIP headers (added to INVITE)") {
            ForEach(draft.customHeaders) { header in
                HStack(spacing: 6) {
                    TextField("Name", text: customHeaderBinding(id: header.id, keyPath: \.name),
                              prompt: Text("X-Custom-Header"))
                        .frame(maxWidth: .infinity)
                    TextField("Value", text: customHeaderBinding(id: header.id, keyPath: \.value),
                              prompt: Text("value"))
                        .frame(maxWidth: .infinity)
                    Button {
                        draft.customHeaders.removeAll { $0.id == header.id }
                        hasUnsavedChanges = true
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove header")
                }
            }
            Button {
                draft.customHeaders.append(SIPCustomHeader())
                hasUnsavedChanges = true
            } label: {
                Label("Add header", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    /// Two-way binding into `draft.customHeaders[id].keyPath` that flips
    /// `hasUnsavedChanges` on every edit. Avoids `ForEach($collection)`'s
    /// constraint that the collection itself be a Binding.
    private func customHeaderBinding(
        id: UUID,
        keyPath: WritableKeyPath<SIPCustomHeader, String>
    ) -> Binding<String> {
        Binding(
            get: {
                draft.customHeaders.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                if let idx = draft.customHeaders.firstIndex(where: { $0.id == id }),
                   draft.customHeaders[idx][keyPath: keyPath] != newValue {
                    draft.customHeaders[idx][keyPath: keyPath] = newValue
                    hasUnsavedChanges = true
                }
            }
        )
    }

    @ViewBuilder
    private var saveAsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as new profile")
                .font(.headline)
            TextField("Profile name", text: $saveAsName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSaveAsSheet = false }
                Button("Save") {
                    var p = draft
                    p = DialerProfile(
                        id: UUID(),
                        name: saveAsName.isEmpty ? "Untitled" : saveAsName,
                        sipHost: p.sipHost, sipPort: p.sipPort, toURI: p.toURI,
                        fromUser: p.fromUser, fromDisplay: p.fromDisplay,
                        authUser: p.authUser,
                        useSTUN: p.useSTUN, stunServer: p.stunServer,
                        localSIPPort: p.localSIPPort, localRTPPort: p.localRTPPort,
                        callDuration: p.callDuration,
                        codecs: p.codecs,
                        transportKind: p.transportKind,
                        allowSelfSignedTLS: p.allowSelfSignedTLS,
                        useSRTP: p.useSRTP,
                        customHeaders: p.customHeaders
                    )
                    appState.upsertProfile(p)
                    appState.selectProfile(p.id)
                    showSaveAsSheet = false
                    hasUnsavedChanges = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: - Helpers

    private func syncFromSelection() {
        if let p = appState.profile(id: appState.selectedProfileID) {
            draft = p
            hasUnsavedChanges = false
        } else if let p = appState.profiles.first {
            appState.selectProfile(p.id)
            draft = p
            hasUnsavedChanges = false
        } else {
            draft = DialerProfile(name: "New Profile")
            hasUnsavedChanges = true
        }
    }

    // MARK: - Profile import / export

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.title = "Export Profile"
        let safeName = draft.name.replacingOccurrences(of: "/", with: "_")
        panel.nameFieldStringValue = "\(safeName).sipcall"
        panel.canCreateDirectories = true
        if let utType = UTType(filenameExtension: "sipcall") {
            panel.allowedContentTypes = [utType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SIPCallExport.encode(profile: draft)
            try data.write(to: url, options: .atomic)
        } catch {
            showSavePanelError("Failed to export profile",
                               message: error.localizedDescription)
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import Profile"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let utType = UTType(filenameExtension: "sipcall") {
            panel.allowedContentTypes = [utType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try SIPCallExport.decode(data: data)
            appState.upsertProfile(imported)
            appState.selectProfile(imported.id)
            syncFromSelection()
        } catch {
            showSavePanelError("Failed to import profile",
                               message: error.localizedDescription)
        }
    }

    private func showSavePanelError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Generic binding into the draft profile that flips `hasUnsavedChanges`
    /// when the value changes.
    private func bind<V: Equatable>(_ keyPath: WritableKeyPath<DialerProfile, V>) -> Binding<V> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                if draft[keyPath: keyPath] != newValue {
                    draft[keyPath: keyPath] = newValue
                    hasUnsavedChanges = true
                }
            }
        )
    }

    /// Binding for UInt16 port fields with a fallback default if parsing fails.
    private func portBind(_ keyPath: WritableKeyPath<DialerProfile, UInt16>,
                          default fallback: UInt16) -> Binding<String> {
        Binding(
            get: { String(draft[keyPath: keyPath]) },
            set: { s in
                let v = UInt16(s) ?? fallback
                if draft[keyPath: keyPath] != v {
                    draft[keyPath: keyPath] = v
                    hasUnsavedChanges = true
                }
            }
        )
    }
}
