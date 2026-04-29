# SipClient

A simple macOS SIP client for testing SIP servers. Mirrors the functionality of
`lkserver/sip_e2e_tester` (the Python harness) with a native Mac UI plus an
audio library for clips that can be played into calls or used in scripted
scenarios.

## Status

Skeleton only. No SIP, RTP, or audio yet — those are coming next. The shell
builds, launches, and shows the tabbed UI.

## Build

This project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen     # one-time
xcodegen generate         # creates SipClient.xcodeproj
open SipClient.xcodeproj  # then run from Xcode (or use xcodebuild below)
```

Command-line build:

```bash
xcodebuild -project SipClient.xcodeproj -scheme SipClient \
  -configuration Debug -destination 'platform=macOS' build
```

The built `.app` lives under `~/Library/Developer/Xcode/DerivedData/SipClient-*/Build/Products/Debug/SipClient.app`.

## Layout

```
Sources/
├── SipClientApp.swift       App entry
├── ContentView.swift        Sidebar + detail view
├── AppState.swift           ObservableObject shared state
├── Info.plist
├── SipClient.entitlements
├── Models/                  Plain data types (WireLogEntry, AudioClip, Scenario)
├── Views/                   SwiftUI tabs (Dialer / Inbound / Audio Library / Scenarios / Wire Log)
├── SIP/                     (TODO) UAC, UAS, SDP, digest auth
├── STUN/                    (TODO) Public IP/port discovery
├── RTP/                     (TODO) RTP send/recv, G.711, telephone-event DTMF
└── Audio/                   (TODO) AVAudioEngine mic capture, WAV I/O
```

## Notes

- App sandbox is disabled in entitlements so the client can bind UDP ports
  freely (SIP 5060, RTP, STUN). This is a developer test tool, not a
  production softphone.
- Mic permission is declared in `Info.plist`
  (`NSMicrophoneUsageDescription`).
