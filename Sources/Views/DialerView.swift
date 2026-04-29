import SwiftUI

struct DialerView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("dialer.sipHost") private var sipHost: String = ""
    @AppStorage("dialer.sipPort") private var sipPort: String = "5060"
    @AppStorage("dialer.toURI") private var toURI: String = ""
    @AppStorage("dialer.fromUser") private var fromUser: String = "sip-client"
    @AppStorage("dialer.fromDisplay") private var fromDisplay: String = "SIP Client"
    @AppStorage("dialer.authUser") private var authUser: String = ""
    @AppStorage("dialer.useSTUN") private var useSTUN: Bool = true
    @AppStorage("dialer.stunServer") private var stunServer: String = ""
    @AppStorage("dialer.callDuration") private var callDuration: Double = 30
    @AppStorage("dialer.localSIPPort") private var localSIPPort: String = "5060"
    @AppStorage("dialer.localRTPPort") private var localRTPPort: String = "10000"

    // Auth password is intentionally not persisted to AppStorage.
    @State private var authPassword: String = ""

    var body: some View {
        Form {
            Section("Target") {
                TextField("SIP server host", text: $sipHost,
                          prompt: Text("sip.example.com"))
                TextField("SIP port", text: $sipPort)
                TextField("To URI", text: $toURI,
                          prompt: Text("sip:+15551234567@sip.example.com"))
            }

            Section("Caller identity") {
                TextField("From user", text: $fromUser)
                TextField("From display name", text: $fromDisplay)
            }

            Section("Auth (optional)") {
                TextField("Auth username (defaults to From user)", text: $authUser)
                SecureField("Auth password", text: $authPassword)
            }

            Section("NAT") {
                Toggle("Use STUN", isOn: $useSTUN)
                TextField("STUN server (blank = default)", text: $stunServer)
                    .disabled(!useSTUN)
            }

            Section("Local") {
                TextField("Local SIP port", text: $localSIPPort)
                TextField("Local RTP port", text: $localRTPPort)
                HStack {
                    Text("Call duration after answer: \(Int(callDuration))s")
                    Slider(value: $callDuration, in: 5...300, step: 5)
                }
            }

            Section {
                HStack {
                    if appState.callInProgress {
                        Button("Hang up", role: .destructive) {
                            appState.hangup()
                        }
                    } else {
                        Button("Place Call") {
                            place()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(sipHost.isEmpty || toURI.isEmpty)
                    }
                    Spacer()
                    Text(appState.callStatus)
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .lineLimit(2)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Dialer")
    }

    private func place() {
        var cfg = SIPCallConfig(sipHost: sipHost.trimmingCharacters(in: .whitespaces))
        cfg.sipPort = UInt16(sipPort) ?? 5060
        cfg.toURI = toURI.trimmingCharacters(in: .whitespaces)
        cfg.fromUser = fromUser
        cfg.fromDisplay = fromDisplay
        cfg.authUser = authUser
        cfg.authPassword = authPassword
        cfg.useSTUN = useSTUN
        cfg.stunServer = stunServer
        cfg.localSIPPort = UInt16(localSIPPort) ?? 5060
        cfg.localRTPPort = UInt16(localRTPPort) ?? 10000
        cfg.callDuration = callDuration
        appState.placeCall(config: cfg)
    }
}
