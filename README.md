# ASTER Mobile (iOS)

Native Swift/WKWebView implementation of the ASTER mobile experience, mirroring the Android and desktop security architecture under the 5.0 parity program.

> **Status: source only — never compiled.** No Mac/Xcode environment was available during development. No IPA exists. Nothing in this repository has been validated by an Xcode build or test run.

## What's here

- `Sources/` — app code: `BrowserController.swift` (WKWebView tabs incl. nonpersistent private-tab data store), `BrowserStore.swift` (JSON profile with file protection), `DownloadCoordinator.swift` (HTTPS-only, 100 MiB cap, no redirects, local checks — not antivirus), `NativeScreens.swift`, `SecurityPolicy.swift` (URL policy / MobileShield / DownloadInspector mirrors of the Kotlin logic)
- `Tests/SecurityPolicyTests.swift` — XCTest suite for the pure policy code
- `project.yml` — XcodeGen spec (iOS 16.0, Swift 5, `app.aster.mobile` placeholder bundle ID)
- `Resources/` — Info.plist (camera/mic usage strings), LaunchScreen storyboard
- `build-ios.sh` — reproducible build script: `simulator` | `test` | `archive` | `export` modes
- `IOS-BUILD.md` — full owner build/signing handoff

## Build requirements (owner-provided)

- macOS with **Xcode 16**
- **XcodeGen 2.42.0** (`brew install xcodegen`)
- For archive/export: an Apple Developer team ID, the final bundle identifier, and an export-options plist. Never commit certificates or provisioning profiles.

## Build

```bash
cd mobile/ios
xcodegen generate --spec project.yml
# Simulator, no signing:
bash build-ios.sh simulator
# Tests (owner sets destination):
ASTER_IOS_DESTINATION="platform=iOS Simulator,id=UUID" bash build-ios.sh test
# Archive (owner sets team + bundle id):
ASTER_APPLE_TEAM="TEAMID" ASTER_IOS_BUNDLE_ID="com.you.aster" bash build-ios.sh archive
# IPA export (owner-reviewed export options plist):
ASTER_EXPORT_OPTIONS=/path/ExportOptions.plist bash build-ios.sh export
```

CI (`.github/workflows/ios-validate.yml`) runs on macOS runners: installs XcodeGen, generates the project, and builds for the simulator with signing disabled. **No IPA is produced** — an unsigned IPA is not installable and is never fabricated. A signed archive requires the owner's Apple Developer credentials and is intentionally not automated here.

## Honest limitations

- Compilation, simulator runs, XCTest results, archive and export all require a Mac — none have ever been executed for this project
- WKWebView cannot use Safari Web Extensions; Mobile Shield content-rule blocking (`SFContentRuleList`) is the supported alternative
- App Store / TestFlight distribution is not configured

## License

MIT — see [LICENSE](./LICENSE).
