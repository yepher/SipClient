import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case dialer = "Dialer"
    case inbound = "Inbound"
    case audio = "Audio Library"
    case scenarios = "Scenarios"
    case wireLog = "Wire Log"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dialer: return "phone.arrow.up.right"
        case .inbound: return "phone.arrow.down.left"
        case .audio: return "waveform"
        case .scenarios: return "list.bullet.rectangle"
        case .wireLog: return "doc.text.magnifyingglass"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarTab? = .dialer

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, id: \.self, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
            }
            .navigationTitle("SIP Client")
            .frame(minWidth: 180)
        } detail: {
            switch selection ?? .dialer {
            case .dialer: DialerView()
            case .inbound: InboundView()
            case .audio: AudioLibraryView()
            case .scenarios: ScenariosView()
            case .wireLog: WireLogView()
            }
        }
    }
}
