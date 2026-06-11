# Vanta Playground — macOS app

A native macOS app that opens the Vanta playground and CHIP-8 emulator. It is a
thin Swift `WKWebView` shell around the web playground — which means **all of the
actual content (the Vanta language and the emulator) is Vanta**; this shell is
the small amount of native code Apple requires to ship an app.

It loads the live playground at `https://juanshep1.github.io/vanta/playground/`,
so you need GitHub Pages enabled on the repo (and a network connection).

## Build it — option A: XcodeGen (fastest)

```bash
brew install xcodegen          # if you don't have it
cd app/macos
xcodegen generate              # creates VantaPlayground.xcodeproj
open VantaPlayground.xcodeproj  # then press Run (Cmd-R) in Xcode
```

## Build it — option B: by hand in Xcode

1. Xcode ▸ File ▸ New ▸ Project ▸ **macOS** ▸ **App**. Interface: **SwiftUI**,
   Language: **Swift**. Name it `VantaPlayground`.
2. Delete the generated `ContentView.swift` and the generated `…App.swift`.
3. Drag in `Sources/VantaPlaygroundApp.swift` and `Sources/WebView.swift`.
4. Select the target ▸ **Signing & Capabilities** ▸ add the **App Sandbox**
   capability and check **Outgoing Connections (Client)** (this is the
   `com.apple.security.network.client` entitlement — without it the sandbox
   blocks the WebView from loading the page).
5. Set the deployment target to macOS 13 or later. Press **Run**.

## Files
- `Sources/VantaPlaygroundApp.swift` — the `@main` SwiftUI app (one window).
- `Sources/WebView.swift` — a `WKWebView` wrapped for SwiftUI.
- `Info.plist`, `Vanta.entitlements` — app metadata and the network entitlement.
- `project.yml` — the XcodeGen spec for option A.

## Offline / bundled (future)
This version loads the playground over the network. A later version can bundle
`vanta.py`, the playground, and the ROMs into the app and load them locally —
deferred because Pyodide still fetches its WASM runtime from a CDN.
