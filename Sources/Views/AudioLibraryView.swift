import SwiftUI

struct AudioLibraryView: View {
    @EnvironmentObject var appState: AppState
    @State private var recording: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    // TODO: wire to AudioEngine.startRecording / stopRecording
                    recording.toggle()
                } label: {
                    Label(recording ? "Stop Recording" : "Record New Clip",
                          systemImage: recording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(recording ? .red : .accentColor)

                Spacer()

                Button {
                    // TODO: import WAV
                } label: {
                    Label("Import WAV", systemImage: "square.and.arrow.down")
                }
            }
            .padding()

            Divider()

            if appState.audioClips.isEmpty {
                ContentUnavailableView(
                    "No clips yet",
                    systemImage: "waveform",
                    description: Text("Record a clip or import a WAV to use during calls and scenarios.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.audioClips) { clip in
                    HStack {
                        Image(systemName: "waveform")
                        VStack(alignment: .leading) {
                            Text(clip.name)
                            Text(String(format: "%.1fs", clip.durationSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Play") { /* TODO */ }
                    }
                }
            }
        }
        .navigationTitle("Audio Library")
    }
}
