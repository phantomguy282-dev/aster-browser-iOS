# Aster iOS build handoff (owner-gated)

This document describes how the owner builds, tests, signs and ships the iOS
app. Nothing in this repository has been compiled with Xcode; no IPA, no App
Store submission and no TestFlight distribution exists yet.

## Prerequisites (owner-provided, not included)

- A Mac with macOS and **Xcode 16** (project specifies `xcodeVersion: 16.0`,
  iOS deployment target 16.0, Swift 5).
- **XcodeGen 2.42.0** to generate `AsterMobile.xcodeproj` from `project.yml`.
- An Apple Developer account with a team ID, and for distribution an App
  Store Connect record for the final bundle identifier.
- The final bundle identifier is the owner's decision; the placeholder in
  `project.yml` is `app.aster.mobile`.

## Source contents

- `Sources/` — Swift app sources (browser, store, download coordinator,
  native screens, security policy). Written but never compiled.
- `Tests/SecurityPolicyTests.swift` — XCTest suite for the pure policy code
  (URL policy, shield modes, filename sanitisation, local download checks).
- `Resources/Info.plist`, `Resources/LaunchScreen.storyboard`.
- `build-ios.sh` — reproducible build script; see modes below.

No app icon set (`AppIcon`) exists yet; add one in `Resources/` before
release builds. The scheme references `AsterMobileTests`.

## Build modes

```bash
cd mobile/ios

# 1. Simulator build, no signing required (first verification step on a Mac)
bash build-ios.sh simulator

# 2. Run the XCTest suite on an installed simulator
ASTER_IOS_DESTINATION="platform=iOS Simulator,id=SIMULATOR_UUID" bash build-ios.sh test

# 3. Archive with the owner's team and final bundle identifier
ASTER_APPLE_TEAM="TEAMID" ASTER_IOS_BUNDLE_ID="com.owner.aster" bash build-ios.sh archive

# 4. Export an IPA using an owner-reviewed export options plist
ASTER_EXPORT_OPTIONS=/path/to/ExportOptions.plist bash build-ios.sh export
```

Windows note: `build-ios.bat` at the repository root is an honest handoff
stub; it never builds or signs anything and creates no IPA.

## Honest status and gates

- **Implemented and reviewed as source only.** Compilation, simulator run,
  XCTest results, archive and export all require a Mac and have never been
  executed for this project.
- Signing identity, provisioning profiles, bundle identifier and App Store
  metadata are owner decisions; none are embedded in the repository.
- No claim of App Store readiness, TestFlight availability or device testing
  is made until the owner runs the steps above and shares the outcomes.
- Privacy strings in `Info.plist` (camera, microphone) match the app's
  behaviour: access is only requested after an explicit per-site approval
  flow in the app.
