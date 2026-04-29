import SwiftUI

struct ScenariosView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack {
            if appState.scenarios.isEmpty {
                ContentUnavailableView(
                    "No scenarios yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Create a scripted scenario: wait for answer, play a clip, send DTMF, etc.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.scenarios) { scenario in
                    Text(scenario.name)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    let s = Scenario(name: "New Scenario")
                    appState.scenarios.append(s)
                } label: {
                    Label("New Scenario", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Scenarios")
    }
}
