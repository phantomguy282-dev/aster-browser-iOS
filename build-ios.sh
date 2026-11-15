#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-simulator}"
if [[ "$(uname -s)" != Darwin ]]; then echo 'iOS builds require macOS and Xcode; no IPA created.' >&2; exit 1; fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen 2.42.0 (review its official release), then retry.' >&2; exit 1; }
xcodebuild -version
xcodegen generate --spec project.yml
case "$MODE" in
  simulator)
    xcodebuild -project AsterMobile.xcodeproj -scheme AsterMobile -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
    ;;
  test)
    : "${ASTER_IOS_DESTINATION:?Set ASTER_IOS_DESTINATION to an installed simulator, for example platform=iOS Simulator,id=SIMULATOR_UUID}"
    xcodebuild -project AsterMobile.xcodeproj -scheme AsterMobile -destination "$ASTER_IOS_DESTINATION" -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
    ;;
  archive)
    : "${ASTER_APPLE_TEAM:?Set the owner Apple development team ID}"
    : "${ASTER_IOS_BUNDLE_ID:?Set the owner registered bundle identifier}"
    xcodebuild -project AsterMobile.xcodeproj -scheme AsterMobile -configuration Release -destination 'generic/platform=iOS' -archivePath build/AsterMobile.xcarchive DEVELOPMENT_TEAM="$ASTER_APPLE_TEAM" PRODUCT_BUNDLE_IDENTIFIER="$ASTER_IOS_BUNDLE_ID" archive
    ;;
  export)
    : "${ASTER_EXPORT_OPTIONS:?Set ASTER_EXPORT_OPTIONS to an owner-reviewed export options plist}"
    [[ -f "$ASTER_EXPORT_OPTIONS" && -d build/AsterMobile.xcarchive ]] || { echo 'Archive or export options missing' >&2; exit 1; }
    xcodebuild -exportArchive -archivePath build/AsterMobile.xcarchive -exportOptionsPlist "$ASTER_EXPORT_OPTIONS" -exportPath build/export
    ;;
  *) echo 'Usage: bash build-ios.sh simulator|test|archive|export' >&2; exit 2 ;;
esac
