import CoreAudio
import SwiftUI

struct InCallView: View {
    @EnvironmentObject var appState: AppState

    /// Tapped to start a new call when idle. When nil the Place Call
    /// button is hidden (e.g. inbound-only view).
    var onPlaceCall: (() -> Void)? = nil
    /// Disables the Place Call button (e.g. when the dialer profile
    /// hasn't filled in a target host / URI yet).
    var placeCallDisabled: Bool = false

    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !collapsed {
                audioDeviceRow
                if appState.callInProgress {
                    callDetails
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
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: stateIcon)
                .font(.title2)
                .foregroundStyle(stateIconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateTitle)
                    .font(.headline)
                Text(appState.callStatus.isEmpty ? "Idle" : appState.callStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Expand" : "Collapse")

            if appState.callInProgress {
                Button("Hang up", role: .destructive) {
                    appState.hangup()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.escape)
            } else if let onPlaceCall {
                Button("Place Call") {
                    onPlaceCall()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(placeCallDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var stateIcon: String {
        guard appState.callInProgress else { return "phone" }
        return appState.callConnected ? "phone.connection.fill" : "phone.arrow.up.right"
    }

    private var stateIconColor: Color {
        guard appState.callInProgress else { return .secondary }
        return appState.callConnected ? .green : .orange
    }

    private var stateTitle: String {
        guard appState.callInProgress else { return "Ready" }
        return appState.callConnected ? "In Call" : "Calling…"
    }

    @ViewBuilder
    private var callDetails: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VUMeter(level: appState.audioEngine.sendLevel,
                    label: "Send", color: .blue)
            VUMeter(level: appState.audioEngine.recvLevel,
                    label: "Recv", color: .green)
        }

        HStack(alignment: .top, spacing: 12) {
            DTMFKeypad { digit in
                appState.sendDTMF(String(digit))
            }
            .frame(maxWidth: 240)

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.rtpStats.isEmpty ? "RTP …" : appState.rtpStats)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                if !appState.callConnected {
                    Text("Waiting for answer — DTMF not available yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var audioDeviceRow: some View {
        HStack(spacing: 8) {
            Button {
                appState.toggleMicMuted()
            } label: {
                Image(systemName: appState.micMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(appState.micMuted ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(appState.micMuted ? "Unmute microphone" : "Mute microphone")
            Picker("", selection: Binding<AudioDeviceID>(
                get: { appState.selectedInputDeviceID },
                set: { appState.setInputDevice($0) }
            )) {
                ForEach(appState.inputDevices) { d in
                    Text(d.name).tag(d.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Image(systemName: "speaker.wave.2")
                .foregroundStyle(.secondary)
            Picker("", selection: Binding<AudioDeviceID>(
                get: { appState.selectedOutputDeviceID },
                set: { appState.setOutputDevice($0) }
            )) {
                ForEach(appState.outputDevices) { d in
                    Text(d.name).tag(d.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Button {
                appState.refreshAudioDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh device list")
        }
    }
}

struct VUMeter: View {
    let level: Double
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [color, .yellow, .red],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(0, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(height: 12)
        }
    }
}

private struct DTMFKeypad: View {
    let onDigit: (Character) -> Void

    private let layout: [[Character]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"]
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<layout.count, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(layout[row], id: \.self) { ch in
                        Button {
                            onDigit(ch)
                        } label: {
                            Text(String(ch))
                                .font(.title3.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}
