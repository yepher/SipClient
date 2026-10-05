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
                Menu {
                    Button("Blank scenario") {
                        add(Scenario(name: "New Scenario", steps: [
                            .waitForAnswer(timeout: 30)
                        ]))
                    }
                    Button("Agent round-trip test (one-way audio, ×100)") {
                        add(.agentRoundTripTemplate(profileID: appState.selectedProfileID))
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
                            appState.upsertScenario(scenario.duplicate(named: scenario.name + " copy"))
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
                currentIteration: appState.runningScenarioID == draft.id
                    ? appState.currentScenarioIteration : nil,
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

    private func add(_ scenario: Scenario) {
        appState.upsertScenario(scenario)
        appState.selectScenario(scenario.id)
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
    let currentIteration: Int?
    let hasUnsavedChanges: Bool
    let onSave: () -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            runSettings
            Divider()
            stepsList
            ScenarioRunPanel(scenarioID: scenario.id)
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
            Button("Wait for far-end speech") { scenario.steps.append(.waitForSpeech(timeout: 15)) }
            Button("Speak text") { scenario.steps.append(.speak(text: "What is the capital of Illinois?")) }
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
                .disabled(scenario.steps.isEmpty
                          || (scenario.repeatCount > 1 && scenario.profileID == nil))
            }
            Spacer()
            if let i = currentStep, isRunning {
                Text((currentIteration.map { "Call \($0) of \(scenario.repeatCount) · " } ?? "")
                     + "Step \(i + 1) of \(scenario.steps.count)")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var runSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Repeat").foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { scenario.repeatCount },
                    set: { scenario.repeatCount = max(1, min(10_000, $0)) }
                ), format: .number)
                .frame(width: 60)
                Text("times").foregroundStyle(.secondary)
                if scenario.repeatCount > 1 {
                    Text("· pause").foregroundStyle(.secondary)
                    TextField("", value: $scenario.pauseBetweenRuns, format: .number)
                        .frame(width: 44)
                    Text("s between calls").foregroundStyle(.secondary)
                    Picker("", selection: $scenario.recordingPolicy) {
                        ForEach(ScenarioRecordingPolicy.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if scenario.repeatCount > 1 && scenario.profileID == nil {
                Label("Pick a profile — each repetition dials a new call.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                Text("Speech above").foregroundStyle(.secondary)
                TextField("", value: $scenario.speechThresholdDbfs, format: .number)
                    .frame(width: 44)
                Text("dBFS · turn ends after").foregroundStyle(.secondary)
                TextField("", value: $scenario.endOfTurnSilence, format: .number)
                    .frame(width: 44)
                Text("s of silence").foregroundStyle(.secondary)
                Spacer()
                Toggle("Send silence instead of mic", isOn: $scenario.ignoreMicrophone)
                    .help("Keeps room noise from reaching the far end while the "
                          + "scenario runs. Prompts still play.")
            }
        }
        .font(.callout)
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
        case .waitForSpeech(let timeout):
            HStack(spacing: 6) {
                Text("Wait for far-end speech, timeout").foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { timeout },
                    set: { step = .waitForSpeech(timeout: $0) }
                ), format: .number)
                .frame(width: 60)
                Text("s, then let them finish").foregroundStyle(.secondary)
            }
            .help("Fails if the far end isn't heard in time. Once it is, waits for "
                  + "the scenario's end-of-turn silence before the next step.")
        case .speak(let text):
            HStack(spacing: 6) {
                Text("Speak").foregroundStyle(.secondary)
                TextField("text", text: Binding(
                    get: { text },
                    set: { step = .speak(text: $0) }
                ))
                .textFieldStyle(.roundedBorder)
            }
            .help("Spoken into the call with the system voice. Nothing plays locally.")
        }
    }
}

/// Live and final results of the scenario's latest run: pass/fail
/// counts, success rate, and the failed calls to go and look at.
private struct ScenarioRunPanel: View {
    @EnvironmentObject var appState: AppState
    let scenarioID: UUID

    var body: some View {
        if let run = appState.scenarioRun, run.scenarioID == scenarioID {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Last run").font(.headline)
                    ProgressView(value: Double(run.results.count),
                                 total: Double(max(1, run.plannedIterations)))
                        .frame(maxWidth: 160)
                    Text("\(run.results.count)/\(run.plannedIterations)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Label("\(run.passed)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Label("\(run.failed)", systemImage: "xmark.circle.fill")
                        .foregroundStyle(run.failed > 0 ? .red : .secondary)
                    if !run.results.isEmpty {
                        Text(String(format: "%.1f%% success", run.successRate * 100))
                            .bold()
                    }
                    if run.cancelled {
                        Text("cancelled").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Copy Report") { appState.copyScenarioReport() }
                    Button("Show Files") { appState.revealScenarioReport() }
                        .disabled(appState.scenarioRunReportURL == nil)
                }
                .labelStyle(.titleAndIcon)
                if !run.failures.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(run.failures) { f in
                                failureRow(f)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
            .font(.callout)
            .padding(12)
        }
    }

    private func failureRow(_ f: ScenarioIterationResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("#\(f.iteration)").monospacedDigit().bold()
                Text(f.startedAt, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                Text(f.callID)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if let path = f.recordingPath {
                    Button {
                        appState.revealInFinder(URL(fileURLWithPath: path))
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .buttonStyle(.borderless)
                    .help("Show this call's recording (left = us, right = far end)")
                }
            }
            Text("Step \((f.failedStep ?? 0) + 1) (\(f.failedStepLabel ?? "?")): \(f.reason ?? "")")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !f.correlationHeaders.isEmpty {
                Text(f.correlationHeaders.sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }.joined(separator: "  "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
