<div align="center">

# Vibelimit

**Your coding subscription limits in the macOS menu bar.**

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple)](https://github.com/Simskii/vibelimit/releases)
[![Release](https://img.shields.io/github/v/release/Simskii/vibelimit?display_name=tag&sort=semver)](https://github.com/Simskii/vibelimit/releases/latest)
[![Tests](https://github.com/Simskii/vibelimit/actions/workflows/ci.yml/badge.svg)](https://github.com/Simskii/vibelimit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-3de67d.svg)](LICENSE)

<br />

<img src="docs/vibelimit-panel.png" width="344" alt="Vibelimit showing the remaining Codex weekly limit and reset time" />

<br />

[Download the latest DMG](https://github.com/Simskii/vibelimit/releases/latest) · [View source](https://github.com/Simskii/vibelimit)

</div>

## Why Vibelimit?

Subscription limits are easy to forget until they interrupt your work. Vibelimit keeps
the remaining capacity and next reset visible without requiring another browser
tab or dashboard. View Codex, Claude Code, GitHub Copilot, and Cursor together in one panel.

- Remaining capacity for the selected subscription directly in the menu bar
- Codex, Claude Code, GitHub Copilot, and Cursor connectors
- Clear limit windows, progress bars, and reset countdowns
- Optional notifications when capacity is low, exhausted, or restored
- Reset-credit and stale-data status
- Launch at login, no Dock icon, and a compact native interface
- Read-only access through the local Codex App Server

## Install

1. Download the latest `Vibelimit-*.dmg` from
   [GitHub Releases](https://github.com/Simskii/vibelimit/releases/latest).
2. Open the DMG and drag **Vibelimit** to **Applications**.
3. Launch Vibelimit. The selected subscription’s percentage appears in the menu bar.

Unsigned preview releases require one additional first-launch step: right-click
Vibelimit in Finder and choose **Open**. Developer ID signed and notarized
releases open normally through Gatekeeper.

### Requirements

- macOS 13 Ventura or later
- An existing sign-in for at least one supported provider
- For Codex: ChatGPT for macOS or a Codex CLI build that supports `app-server`

### Subscription connectors

Connected subscriptions appear as stacked sections in one scrollable panel.
Providers without a successful usage response are hidden; previously loaded
providers remain visible with cached data if a refresh fails. All providers are
checked every five minutes, so newly connected subscriptions appear automatically. Each provider keeps its own cached data, connection
status, and notifications. Use **Menu bar subscription** in the actions menu to
choose which subscription supplies the menu-bar percentage. That choice is remembered.

- **Codex:** uses the local `codex app-server --stdio` process as before.
- **Claude Code:** shows five-hour and weekly usage. Reads Claude Code's
  `~/.claude/.credentials.json`, or its `Claude Code-credentials` Keychain item.
  A custom `CLAUDE_CONFIG_DIR` uses only that profile's credentials file.
  If Keychain access is needed, choose **Allow Claude Keychain Access** in the
  actions menu. Automatic refreshes never open a Keychain permission prompt.
  Expired credentials must be renewed through Claude Code. A `setup-token`
  token without `user:profile` scope cannot read subscription usage.
- **GitHub Copilot:** shows premium requests, chat, and completions when returned.
  Reads an existing GitHub.com sign-in from
  `~/.config/github-copilot/apps.json` or `hosts.json`, respecting `XDG_CONFIG_HOME`.
  Multiple different tokens in a file require resolving the active account in
  the editor. Enterprise hosts and editors that store credentials only in their
  own secret storage are not supported in this version.

- **Cursor:** reads the signed-in Cursor app's
  `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` database
  read-only. Shows included plan usage, a personal spending cap when reported,
  and on-demand spending separately. Expired sessions must be renewed in Cursor.
  Legacy request-count plans and shared team pools are not supported in this version.

Claude, Copilot, and Cursor use unofficial usage endpoints that can change. Missing quotas
stay unavailable; unlimited quotas are labelled explicitly. Vibelimit never
refreshes or rewrites provider credentials. No browser-cookie import is used.

## Privacy

Codex uses the local, read-only `account/rateLimits/read` method. When selected,
Claude sends its existing access token to `api.anthropic.com/api/oauth/usage`, and
Copilot sends its existing GitHub token to `api.github.com/copilot_internal/user`.
Cursor sends a session cookie derived from its local access token only to
`cursor.com/api/usage-summary`. These are read-only usage requests. Tokens are read on demand and never saved by
Vibelimit. Usage snapshots remain in memory. It does not:

- store credentials or usage history
- initiate login
- consume reset credits
- modify Codex configuration
- scrape ChatGPT
- send analytics

## Build from source

```sh
xcodebuild \
  -project Vibelimit.xcodeproj \
  -scheme Vibelimit \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  test
```

Build and package a local DMG:

```sh
xcodebuild \
  -project Vibelimit.xcodeproj \
  -scheme Vibelimit \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build

Scripts/package_release.sh 1.0.0
```

The DMG and its SHA-256 checksum are written to `build/release/`.

## Releases

Every push to `main` runs the test suite and updates a Release Please pull
request from conventional commits. Merging that pull request creates the next
semantic version and automatically builds, verifies, and publishes its DMG and
checksum to GitHub Releases. The release workflow can also be run manually.

When the five Apple release secrets documented in
[`.github/workflows/release.yml`](.github/workflows/release.yml) are configured,
the same workflow Developer ID-signs and notarizes the DMG before publishing it.
Notarization is a Gatekeeper security check for direct downloads; it does not
publish Vibelimit to the Mac App Store.

## Author

Built by [Simon Lundh](https://simonlundh.se).

## License

[MIT](LICENSE)
