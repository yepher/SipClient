import SwiftUI

struct InboundView: View {
    @State private var listenPort: String = "5060"
    @State private var listening: Bool = false

    var body: some View {
        Form {
            Section("Listener") {
                TextField("Listen port", text: $listenPort)
                    .disabled(listening)
                HStack {
                    Button(listening ? "Stop" : "Start listening") {
                        // TODO: wire to SIPServer
                        listening.toggle()
                    }
                    Spacer()
                    Text(listening ? "Listening" : "Stopped")
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            Section("Inbound calls") {
                Text("No calls yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Inbound")
    }
}
