# Vibelimit

Vibelimit is a compact, read-only macOS menu-bar monitor for Codex limits.

It talks to the local Codex App Server provided by ChatGPT, reuses the existing
ChatGPT sign-in, and does not store credentials or usage history.

## Features

- Shows the primary Codex percentage directly in the macOS menu bar
- Displays reset time, window duration, reset credits, and stale-data state
- Sends optional notifications at 10%, when the limit is reached, and when
  Codex becomes available again
- Refreshes from the local Codex App Server without browser scraping
- Launches at login and stays out of the Dock
- Keeps the menu-bar label monochrome white

## Requirements

- macOS 13 or later
- Xcode 15 or later
- ChatGPT for macOS or another Codex CLI build that supports `app-server`

## Build and test

```sh
xcodebuild \
  -project Vibelimit.xcodeproj \
  -scheme Vibelimit \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  build

xcodebuild \
  -project Vibelimit.xcodeproj \
  -scheme Vibelimit \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  test
```

The app is intentionally not sandboxed because it launches the locally installed
Codex executable. It only calls the read-only `account/rateLimits/read` method.

## Install locally

Build the Release configuration, copy the app to the user Applications folder,
and open it once:

```sh
xcodebuild \
  -project Vibelimit.xcodeproj \
  -scheme Vibelimit \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build

mkdir -p "$HOME/Applications"

ditto \
  build/DerivedData/Build/Products/Release/Vibelimit.app \
  "$HOME/Applications/Vibelimit.app"

open "$HOME/Applications/Vibelimit.app"
```

The first installed launch enables **Launch at Login**. Use the panel’s ellipsis
menu to refresh, toggle notifications or launch at login, or quit.

## Privacy

Vibelimit communicates only with a local `codex app-server --stdio` process. It
does not store authentication material, initiate login, consume reset credits,
modify Codex configuration, or scrape ChatGPT.

## Contributing

Issues and pull requests are welcome. Please run the Debug test command above
before submitting a change.

## License

MIT — see [LICENSE](LICENSE).
