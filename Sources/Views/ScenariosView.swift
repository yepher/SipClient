import SwiftUI

struct ScenariosView: View {
    @EnvironmentObject var appState: AppState

    @State private var draft: Scenario? = nil
    @State private var hasUnsavedChanges: Bool = false
    @State private var renamingScenario: Scenario?
    @State private var renameText: String = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            detail
                .frame(minWidth: 420)
        }
        .navigationTitle("Scenarios")
        .onAppear { syncDraft() }
        .onChange(of: appState.selectedScenarioID) { _, _ in syncDraft() }
        .sheet(item: $renamingScenario) { scenario in
            renameSheet(for: scenario)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scenarios").font(.headline)
                Spacer()
                Button {
                    let new = Scenario(name: "New Scenario", steps: [
                        .waitForAnswer(timeout: 30)
                    ])
                    appState.upsertScenario(new)
                    appState.selectScenario(new.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(8)
            Divider()
            List(selection: Binding(
                get: { appState.selectedScenarioID },
                set: { appState.selectScenario($0) }
            )) {
                ForEach(appState.scenarios) { scenario in
                    HStack {
                        if appState.runningScenarioID == scenario.id {
                            Image(systemName: "play.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "list.bullet.rectangle")
                                .foregroundStyle(.secondary)
                        }
                        Text(scenario.name)
                    }
                    .tag(scenario.id as UUID?)
                    .contextMenu {
                        Button("Rename") {
                            renameText = scenario.name
                            renamingScenario = scenario
                        }
                        Button("Duplicate") {
                            var copy = scenario
                            copy = Scenario(id: UUID(), name: scenario.name + " copy",
                                            profileID: scenario.profileID, steps: scenario.steps)
                            appState.upsertScenario(copy)
                        }
                        Button("Delete", role: .destructive) {
                            appState.deleteScenario(id: scenario.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let draft = draft, appState.scenario(id: draft.id) != nil {
            ScenarioEditor(
                scenario: Binding(
                    get: { self.draft ?? draft },
                    set: { self.draft = $0; hasUnsavedChanges = true }
                ),
                profiles: appState.profiles,
                clips: appState.audioClips,
                isRunning: appState.runningScenarioID == draft.id,
                currentStep: appState.runningScenarioID == draft.id ? appState.currentScenarioStep : nil,
                hasUnsavedChanges: hasUnsavedChanges,
                onSave: {
                    if let d = self.draft {
                        appState.upsertScenario(d)
                        hasUnsavedChanges = false
                    }
                },
                onRun: {
                    if let d = self.draft {
                        appState.runScenario(d)
                    }
                },
                onCancel: { appState.cancelScenario() }
            )
        } else {
            ContentUnavailableView(
                "No scenario selected",
                systemImage: "list.bullet.rectangle",
                description: Text("Pick a scenario on the left, or click + to create one.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func renameSheet(for scenario: Scenario) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename scenario").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { renamingScenario = nil }
                Button("Save") {
                    var s = scenario
                    s.name = renameText.isEmpty ? scenario.name : renameText
                    appState.upsertScenario(s)
                    renamingScenario = nil
                    syncDraft()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func syncDraft() {
        if let s = appState.scenario(id: appState.selectedScenarioID) {
            draft = s
            hasUnsavedChanges = false
        } else {
            draft = nil
            hasUnsavedChanges = false
        }
    }
}

private struct ScenarioEditor: View {
    @Binding var scenario: Scenario
    let profiles: [DialerProfile]
    let clips: [AudioClip]
    let isRunning: Bool
    let currentStep: Int?
    let hasUnsavedChanges: Bool
    let onSave: () -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            stepsList
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading) {
                Text(scenario.name).font(.title2)
                HStack(spacing: 6) {
                    Text("Profile:")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $scenario.profileID) {
                        Text("(use active call)").tag(UUID?.none)
                        ForEach(profiles) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            }
            Spacer()
            if hasUnsavedChanges {
                Text("Unsaved")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                onSave()
            } label: {
                Label("Save", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(!hasUnsavedChanges)
        }
        .padding(12)
    }

    @ViewBuilder
    private var stepsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(scenario.steps.enumerated()), id: \.offset) { idx, _ in
                    StepRow(
                        index: idx,
                        step: $scenario.steps[idx],
                        clips: clips,
                        isCurrent: currentStep == idx,
                        onMoveUp: idx > 0 ? { swap(idx, idx - 1) } : nil,
                        onMoveDown: idx < scenario.steps.count - 1 ? { swap(idx, idx + 1) } : nil,
                        onRemove: { scenario.steps.remove(at: idx) }
                    )
                }
                addStepMenu
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var addStepMenu: some View {
        Menu {
            Button("Wait for answer") { scenario.steps.append(.waitForAnswer(timeout: 30)) }
            Button("Wait")             { scenario.steps.append(.wait(seconds: 1)) }
            Button("Play clip") {
                if let first = clips.first {
                    scenario.steps.append(.playClip(clipID: first.id))
                }
            }
            Button("Send DTMF")        { scenario.steps.append(.sendDTMF(digits: "1")) }
            Button("Hang up")          { scenario.steps.append(.hangup) }
        } label: {
            Label("Add Step", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 160, alignment: .leading)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if isRunning {
                Button("Cancel", role: .destructive, action: onCancel)
            } else {
                Button {
                    onRun()
                } label: {
                    Label("Run Scenario", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(scenario.steps.isEmpty)
            }
            Spacer()
            if let i = currentStep, isRunning {
                Text("Step \(i + 1) of \(scenario.steps.count)")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
        }
        .padding(12)
    }

    private func swap(_ a: Int, _ b: Int) {
        guard scenario.steps.indices.contains(a),
              scenario.steps.indices.contains(b) else { return }
        let tmp = scenario.steps[a]
        scenario.steps[a] = scenario.steps[b]
        scenario.steps[b] = tmp
    }
}

private struct StepRow: View {
    let index: Int
    @Binding var step: ScenarioStep
    let clips: [AudioClip]
    let isCurrent: Bool
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 22, height: 22)
                Text("\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
            }
            stepEditor
            Spacer()
            Button { onMoveUp?() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .disabled(onMoveUp == nil)
            Button { onMoveDown?() } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless)
                .disabled(onMoveDown == nil)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? Color.green : Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var stepEditor: some View {
        switch step {
        case .waitForAnswer(let timeout):
            HStack(spacing: 6) {
                Text("Wait for answer, timeout").foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { timeout },
                    set: { step = .waitForAnswer(timeout: $0) }
                ), format: .number)
                .frame(width: 60)
                Text("s").foregroundStyle(.secondary)
            }
        case .wait(let seconds):
            HStack(spacing: 6) {
                Text("Wait").foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { seconds },
                    set: { step = .wait(seconds: $0) }
                ), format: .number)
                .frame(width: 60)
                Text("s").foregroundStyle(.secondary)
            }
        case .playClip(let clipID):
            HStack(spacing: 6) {
                Text("Play clip").foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { clipID },
                    set: { step = .playClip(clipID: $0) }
                )) {
                    ForEach(clips) { clip in
                        Text(clip.name).tag(clip.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
        case .sendDTMF(let digits):
            HStack(spacing: 6) {
                Text("Send DTMF").foregroundStyle(.secondary)
                TextField("digits", text: Binding(
                    get: { digits },
                    set: { step = .sendDTMF(digits: $0) }
                ))
                .frame(width: 140)
                .textFieldStyle(.roundedBorder)
            }
        case .hangup:
            Text("Hang up")
        }
    }
}
