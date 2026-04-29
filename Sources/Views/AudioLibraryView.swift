import SwiftUI
import UniformTypeIdentifiers

struct AudioLibraryView: View {
    @EnvironmentObject var appState: AppState

    @State private var recordingName: String = ""
    @State private var showImporter: Bool = false
    @State private var renameTarget: AudioClip?
    @State private var renameText: String = ""

    private var isRecording: Bool { appState.audioEngine.mode == .record }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if isRecording {
                    TextField("Clip name", text: $recordingName,
                              prompt: Text("My clip"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Button {
                        let name = recordingName.trimmingCharacters(in: .whitespaces)
                        appState.stopRecordingAndSave(name: name.isEmpty ? defaultClipName() : name)
                        recordingName = ""
                    } label: {
                        Label("Stop & Save", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        appState.startRecording()
                    } label: {
                        Label("Record New Clip", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.audioEngine.mode == .call)
                }

                Spacer()

                Button {
                    showImporter = true
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
                    description: Text("Record a clip from the mic, or import a WAV. Clips can be played live during a call.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(appState.audioClips) { clip in
                        ClipRow(clip: clip,
                                callActive: appState.callInProgress,
                                onRename: { newName in appState.renameClip(clip, to: newName) },
                                onPreview: { appState.previewClip(clip) },
                                onPlayIntoCall: { appState.playClipIntoCall(clip) },
                                onDelete: { appState.deleteClip(clip) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Audio Library")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.wav, .audio]) { result in
            switch result {
            case .success(let url):
                let name = url.deletingPathExtension().lastPathComponent
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                do {
                    try appState.importClip(from: url, name: name)
                } catch {
                    appState.appendLog(.init(direction: .sent, kind: .error,
                                             summary: "Import failed: \(error.localizedDescription)"))
                }
            case .failure(let err):
                appState.appendLog(.init(direction: .sent, kind: .error,
                                         summary: "Import cancelled: \(err.localizedDescription)"))
            }
        }
    }

    private func defaultClipName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Clip \(f.string(from: Date()))"
    }
}

private struct ClipRow: View {
    let clip: AudioClip
    let callActive: Bool
    let onRename: (String) -> Void
    let onPreview: () -> Void
    let onPlayIntoCall: () -> Void
    let onDelete: () -> Void

    @State private var editing: Bool = false
    @State private var editText: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                if editing {
                    TextField("Name", text: $editText, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .onExitCommand { editing = false }
                } else {
                    Text(clip.name)
                        .onTapGesture(count: 2) {
                            editText = clip.name
                            editing = true
                        }
                }
                Text(String(format: "%.1fs", clip.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onPreview()
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)

            Button {
                onPlayIntoCall()
            } label: {
                Label("Send to Call", systemImage: "phone.arrow.up.right")
            }
            .buttonStyle(.bordered)
            .disabled(!callActive)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Rename") {
                editText = clip.name
                editing = true
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != clip.name {
            onRename(trimmed)
        }
        editing = false
    }
}
