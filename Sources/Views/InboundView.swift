import AppKit
import SwiftUI

struct InboundView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Listener status / configuration
                listenerCard
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                // SSH tunnel for SIP signaling (TCP). Optional; lets the
                // user expose the listener via a public VPS without
                // touching their router.
                sshTunnelCard
                    .padding(.horizontal, 16)

                // Pending Answer/Reject prompt — shown only while there's an
                // unanswered INVITE.
                if let pending = appState.pendingInbound {
                    pendingCallCard(pending)
                        .padding(.horizontal, 16)
                }

                // Active call body — same widgets as outbound (mute, devices,
                // VU, DTMF, metrics). Hides itself when no call is active.
                if appState.callInProgress {
                    InCallView()
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .navigationTitle("Inbound")
    }

    @ViewBuilder
    private var listenerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: appState.inboundListener.isListening
                      ? "phone.connection.fill"
                      : "phone.down.fill")
                    .font(.title2)
                    .foregroundStyle(appState.inboundListener.isListening
                                     ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.inboundListener.isListening
                         ? "Listening for inbound calls"
                         : "Inbound listener stopped")
                        .font(.headline)
                    if appState.inboundListener.isListening {
                        addressRow(label: "Local",
                                   host: appState.inboundListener.detectedLocalIP,
                                   port: appState.inboundListener.localPort)
                    } else if let err = appState.inboundListener.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if appState.inboundListener.isListening {
                    Button("Stop") {
                        appState.stopInboundListener()
                    }
                } else {
                    Button("Start") {
                        appState.startInboundListener()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }

            if !appState.inboundListener.isListening {
                Form {
                    Section("Local listener") {
                        TextField("Local SIP port",
                                  text: portBind(\.localPort, default: 5060))
                        TextField("Local RTP port (0 = ephemeral)",
                                  text: portBind(\.localRTPPort, default: 0))
                    }
                    Section("STUN (auto-discover RTP public address)") {
                        Toggle("Use STUN for inbound RTP",
                               isOn: boolBind(\.useSTUN))
                        TextField("STUN server (blank = default list)",
                                  text: stringBind(\.stunServer),
                                  prompt: Text("stun.l.google.com"))
                        Text("STUN works for cone NATs (most home routers). "
                             + "If you're on CGNAT or symmetric NAT, fall back "
                             + "to manual port-forwarding or an SSH tunnel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Public address (manual override)") {
                        TextField("Public host (IP or hostname)",
                                  text: stringBind(\.publicHost),
                                  prompt: Text("auto-filled by STUN; override for non-STUN setups"))
                        TextField("Public SIP port (0 = same as local)",
                                  text: portBind(\.publicSIPPort, default: 0))
                        TextField("Public RTP port (0 = STUN result / ephemeral)",
                                  text: portBind(\.publicRTPPort, default: 0))
                        Text("Manual values win over STUN. Leave blank to let "
                             + "STUN populate. See InboundSetup.md.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else if !appState.inboundListener.stunRTPHost.isEmpty {
                // Surface the STUN result while listening so users know
                // what address inbound calls will see in our SDP.
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .foregroundStyle(.green)
                    addressRow(label: "STUN RTP",
                               host: appState.inboundListener.stunRTPHost,
                               port: appState.inboundListener.stunRTPPort)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var sshTunnelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: appState.inboundListener.sshIsRunning
                      ? "lock.shield.fill"
                      : "lock.shield")
                    .font(.title2)
                    .foregroundStyle(appState.inboundListener.sshIsRunning
                                     ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SSH reverse tunnel (SIP/TCP)")
                        .font(.headline)
                    if appState.inboundListener.sshIsRunning {
                        Text("Forwarding "
                             + "\(appState.inboundListener.sshUser)@\(appState.inboundListener.sshHost) "
                             + ":\(verbatimPort(appState.inboundListener.sshRemoteSIPPort)) "
                             + "→ local :\(verbatimPort(appState.inboundListener.localPort))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else if let err = appState.inboundListener.sshLastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Optional — exposes inbound SIP signaling via a public VPS. "
                             + "RTP still flows directly via STUN.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if appState.inboundListener.sshIsRunning {
                    Button("Stop") { appState.inboundListener.stopSSHTunnel() }
                } else {
                    Button("Start") { appState.inboundListener.startSSHTunnel() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(
                            appState.inboundListener.sshHost.isEmpty
                                || appState.inboundListener.sshUser.isEmpty
                        )
                }
            }

            if !appState.inboundListener.sshIsRunning {
                Form {
                    Section {
                        TextField("Host",
                                  text: stringBind(\.sshHost),
                                  prompt: Text("vps.example.com"))
                        TextField("User",
                                  text: stringBind(\.sshUser),
                                  prompt: Text("ubuntu"))
                        TextField("SSH port",
                                  text: portBind(\.sshPort, default: 22))
                        TextField("Remote SIP port (the public port on the VPS)",
                                  text: portBind(\.sshRemoteSIPPort, default: 5060))
                    }
                }
                .formStyle(.grouped)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    /// Stringify a UInt16 port without LocalizedStringKey's thousands
    /// separator getting in the way (`5,060` → `5060`).
    private func verbatimPort(_ port: UInt16) -> String { String(port) }

    @ViewBuilder
    private func pendingCallCard(_ call: InboundCall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "phone.arrow.down.left")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incoming call")
                        .font(.headline)
                    if !call.fromDisplay.isEmpty {
                        Text(call.fromDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(call.fromURI)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Reject", role: .destructive) {
                    appState.rejectInboundCall()
                }
                .keyboardShortcut(.escape)
                Button("Answer") {
                    appState.answerInboundCall()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    /// Selectable, copy-friendly host:port row.
    /// `Text` interpolation of integers goes through LocalizedStringKey
    /// and inserts thousands separators (`5,060`) — `verbatim:` skips
    /// that. `.textSelection(.enabled)` lets the user click-drag to
    /// copy; the icon button drops the address straight on the
    /// pasteboard.
    @ViewBuilder
    private func addressRow(label: String, host: String, port: UInt16) -> some View {
        let address = "\(host):\(port)"
        HStack(spacing: 6) {
            Text(verbatim: "\(label): \(address)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(address, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Copy \(address)")
        }
    }

    /// Two-way binding for UInt16 listener fields that flips through a
    /// String <→> UInt16 with a fallback default. Goes through the
    /// listener-instance keypath, since `appState.inboundListener` is
    /// a `let` (the underlying object's @Published vars are mutable
    /// even though the binding-projection chain isn't reachable).
    private func portBind(_ keyPath: ReferenceWritableKeyPath<InboundListener, UInt16>,
                          default fallback: UInt16) -> Binding<String> {
        Binding(
            get: { String(appState.inboundListener[keyPath: keyPath]) },
            set: { s in
                let v = UInt16(s) ?? fallback
                appState.inboundListener[keyPath: keyPath] = v
            }
        )
    }

    /// Same idea for plain `String` listener fields.
    private func stringBind(_ keyPath: ReferenceWritableKeyPath<InboundListener, String>) -> Binding<String> {
        Binding(
            get: { appState.inboundListener[keyPath: keyPath] },
            set: { appState.inboundListener[keyPath: keyPath] = $0 }
        )
    }

    /// And for Bool toggles (useSTUN).
    private func boolBind(_ keyPath: ReferenceWritableKeyPath<InboundListener, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.inboundListener[keyPath: keyPath] },
            set: { appState.inboundListener[keyPath: keyPath] = $0 }
        )
    }
}
