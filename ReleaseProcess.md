# Release Process

SipClient uses [Sparkle 2](https://sparkle-project.org/) for in-app
auto-updates. The release is automated by `bin/make_release.sh`; this
document explains the one-time setup and the per-release flow.


tldr; after setup:

`./bin/make_release.sh 0.1.0-b8 release_notes/0.1.0-b8.html`

---

## How users see updates

When a new version is published:

- On the next launch (or daily, whichever comes first) the running app
  fetches `appcast.xml` from the URL configured in `Info.plist`
  (`SUFeedURL`).
- If a newer build exists, Sparkle shows the standard
  "A new version of SipClient is available" sheet with release notes.
- Sparkle downloads, EdDSA-verifies, and installs the new build
  in-place. The app relaunches automatically.

Users can also trigger a check manually from the **SipClient → Check
for Updates…** menu item.

---

## How releases are signed

Sparkle relies on **two** independent signatures:

1. **macOS code signature + Apple notarization** — proves the app came
   from your Developer ID. Without this, Gatekeeper blocks the
   downloaded `.zip`.
2. **Sparkle EdDSA signature** — proves the appcast and zip weren't
   tampered with on the way to the user. Sparkle refuses to install an
   update whose enclosure signature doesn't match `SUPublicEDKey` in
   the running app's Info.plist.

The release script handles both.

---

## One-time setup

Do these once per machine you'll release from.

### 1. Add Sparkle to the Xcode project

1. Open `SipClient.xcodeproj` in Xcode.
2. **File → Add Package Dependencies…**
3. Paste `https://github.com/sparkle-project/Sparkle` and click
   **Add Package**.
4. In the package products dialog, tick **Sparkle** and add it to the
   `SipClient` target.
5. Build the app once (⌘B). This populates `~/Library/Developer/Xcode/
   DerivedData` with the `sign_update` and `generate_keys` tools that
   ship inside the Sparkle SPM bundle.

`UpdateController.swift` and the `Check for Updates…` menu item are
gated by `#if canImport(Sparkle)` and become live as soon as the
package is present.

### 2. Generate the EdDSA key pair (Sparkle update signing)

From the project root:

```sh
SPARKLE_DIR=$(find ~/Library/Developer/Xcode/DerivedData \
    -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' \
    -type d 2>/dev/null | head -1)
"$SPARKLE_DIR/generate_keys"
```

This stores the private key in your **login keychain** (item name
`https://sparkle-project.org`) and prints the matching public key.

Export the private key to a file the release script can read — keep it
**off the filesystem of any machine you don't control**:

```sh
"$SPARKLE_DIR/generate_keys" -x ~/.config/sipclient-sparkle.key
chmod 600 ~/.config/sipclient-sparkle.key
```

Copy the printed public key into `Sources/Info.plist` under the
existing empty `SUPublicEDKey` value. Commit the Info.plist change.

> Once a build with a given `SUPublicEDKey` is in users' hands, you
> **must not rotate the key** — running apps will refuse to install
> updates signed with a different one. Back up
> `~/.config/sipclient-sparkle.key` somewhere safe.

### 3. Get a Developer ID Application certificate

The cert you build with day-to-day (`Apple Development`) is *not*
sufficient for distribution. You need a **Developer ID Application**
cert, which is free with your existing Apple Developer membership:

1. Go to [Certificates, IDs & Profiles](https://developer.apple.com/account/resources/certificates/list).
2. Click **+** → **Developer ID Application** → follow the CSR flow.
3. Download the `.cer`, double-click to install into your login keychain.

Verify:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 4. Generate an app-specific password for `notarytool`

[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security
→ App-Specific Passwords → **+** → label it `notarytool`. Save the
generated password.

### 5. Configure the release env file

```sh
cp bin/release.env.example ~/.config/sipclient-release.env
chmod 600 ~/.config/sipclient-release.env
$EDITOR ~/.config/sipclient-release.env
```

Fill in `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`,
`SIGNING_IDENTITY`, and confirm `SPARKLE_PRIVATE_KEY_PATH`.

### 6. (Optional) Test notary credentials

```sh
xcrun notarytool store-credentials sipclient-notary \
    --apple-id "$APPLE_ID" \
    --team-id  "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
```

This is purely a smoke test — the release script passes credentials on
the command line, so it doesn't depend on this profile being saved.

---

## Cutting a release

From the project root, on a clean `main`:

```sh
# Inline HTML release notes
./bin/make_release.sh 0.1.0-b8 \
    "<ul><li>Fix RTP jitter measurement</li><li>RFC-compliant ACK / BYE</li></ul>"

# OR — path to an HTML file (auto-detected if the argument is an existing file)
./bin/make_release.sh 0.1.0-b8 release_notes/0.1.0-b8.html

# OR — no notes argument (uses a default "Release X.Y.Z" message)
./bin/make_release.sh 0.1.0-b8
```

The script is **resumable**. Each phase records a marker in
`build/release/<version>/.state/`; if a transient failure (notary
upload timeout, network blip) interrupts a run, simply re-run the same
command — completed phases are skipped automatically.

To force a clean rebuild for a version that already has cached state:

```sh
REBUILD=1 ./bin/make_release.sh 0.1.0-b8 ...
```

To redo a single phase, delete its marker and re-run, e.g.:

```sh
rm build/release/0.1.0-b8/.state/notarize.done
./bin/make_release.sh 0.1.0-b8 ...
```

This will, in order:

1. Bump `CFBundleShortVersionString` to `0.1.0-b8` and
   `CFBundleVersion` to `git rev-list --count HEAD`.
2. Build the **Release** configuration with manual signing
   (`Developer ID Application`).
3. Submit the build to Apple's notary service and wait
   (~1–3 minutes typically).
4. Staple the notarization ticket onto the `.app`.
5. Re-zip the stapled app as `SipClient-<version>.zip`.
6. EdDSA-sign the zip with `sign_update`.
7. Insert a new `<item>` at the top of `appcast.xml` with the version,
   download URL, length, signature, and the release-notes HTML.

The script then prints the manual finishing steps:

```sh
git diff Sources/Info.plist appcast.xml      # review
git add  Sources/Info.plist appcast.xml
git commit -m "Release 0.1.0-b8"
git tag release_0_1_0_b8
git push --tags && git push

gh release create release_0_1_0_b8 \
    "build/release/0.1.0-b8/SipClient-0.1.0-b8.zip" \
    --title "SipClient 0.1.0-b8" \
    --notes "<ul><li>Fix RTP jitter measurement</li>...</ul>"
```

The push to `main` is what makes the appcast visible to clients —
`SUFeedURL` points at `raw.githubusercontent.com/.../main/appcast.xml`.

---

## What lives where

| File | Role |
| --- | --- |
| `Sources/UpdateController.swift` | SwiftUI wrapper around `SPUStandardUpdaterController`. |
| `Sources/SipClientApp.swift` | Wires the **Check for Updates…** menu command. |
| `Sources/Info.plist` | `SUFeedURL`, `SUPublicEDKey`, automatic-check toggle. |
| `appcast.xml` | Sparkle feed; one `<item>` per release. |
| `bin/make_release.sh` | One-shot build → notarize → sign → appcast pipeline. |
| `bin/update_appcast.py` | Inserts a new `<item>` into `appcast.xml`. |
| `bin/release.env.example` | Template for the secrets the script reads. |
| `~/.config/sipclient-release.env` | Your filled-in copy. **Not committed.** |
| `~/.config/sipclient-sparkle.key` | EdDSA private key. **Not committed.** |

---

## Troubleshooting

**"sign_update: command not found"**
The Sparkle SPM artifact hasn't been pulled into DerivedData yet.
Build the app once in Xcode after adding the package, then re-run.

**Notarization fails with `Invalid bundle`**
Almost always missing `--timestamp` / `--options=runtime` on codesign,
or an unsigned framework being copied into the bundle. The script
passes both; if you customize `OTHER_CODE_SIGN_FLAGS` keep them.

**Update sheet says "the application is signed by an unknown developer"**
The downloaded zip wasn't notarized, or your `Developer ID
Application` cert chain is missing. Verify with
`spctl -a -t exec -vvv SipClient.app`.

**Update sheet says "the update is improperly signed"**
The Sparkle EdDSA signature didn't validate. Causes: wrong
`SUPublicEDKey` baked into the running app, or the appcast `<item>`'s
`sparkle:edSignature` doesn't match the zip on the release page.
Re-running `make_release.sh` regenerates both consistently.

**Users on older builds never see the update**
Check `https://raw.githubusercontent.com/yepher/SipClient/main/appcast.xml`
returns 200 with the new `<item>`. GitHub raw caches for ~5 min.

---

## (Optional) Promoting to a GitHub Action

The bash script is the source of truth. To run it from CI:

1. Store the same env vars as **encrypted repo secrets**
   (Settings → Secrets and variables → Actions).
2. Store the EdDSA private key + your `Developer ID Application` p12
   as additional secrets. Decode and import them into a temporary
   keychain at job start.
3. Trigger the workflow on `push` to a `release/*` branch or by
   manual dispatch with the version string as input.
4. The workflow's job is just: check out, decode keys, write
   `~/.config/sipclient-release.env`, run `./bin/make_release.sh
   "$VERSION"`, commit + push the appcast, and `gh release create`.

A separate `bin/ci_release.sh` wrapping the env-marshalling step keeps
the workflow YAML thin. Add when needed.
