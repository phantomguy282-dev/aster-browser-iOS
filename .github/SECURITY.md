# Security Policy for ASTER Mobile (iOS)

## Reporting

Use GitHub's private vulnerability reporting on this repository: **Security → Report a vulnerability**.

## Honest security posture

- **No compiled artifact exists.** The project has never been built with Xcode; there is no IPA and nothing to install.
- CI (`ios-validate.yml`) builds for the simulator with `CODE_SIGNING_ALLOWED=NO` — validation only, no distributable.
- Signing requires the owner's Apple Developer identity. Never commit certificates, provisioning profiles, or private keys; configure them as repository secrets only if/when automated signing is deliberately set up (not currently).
- Source-level security architecture mirrors the other platforms: HTTPS-only downloads with a 100 MiB cap and local checks (not antivirus), strict origin binding for any future credential storage, Keychain intended for secrets, `SFContentRuleList` for content blocking.
