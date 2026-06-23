# Distribution Strategy

## TL;DR

CapyBuddy ships to the **Mac App Store** as the primary channel. Space Shortcut
is dropped from the App Store build because its core interaction (hold-Space
chord) requires `CGEventTap`, which App Review effectively bans for sandboxed
apps. The feature stays in the codebase and is automatically skipped at runtime
when the app is sandboxed.

If Space Shortcut ever needs to ship to users, the plan is **dual-track
distribution**: App Store version (sandboxed, no Space Shortcut) + Developer ID
version (notarized, full feature set), both built from the same source.

## Why Space Shortcut can't be in the App Store build

### Technical layer — sandbox

Space Shortcut works by:

- `CGEventTapCreate(.cgSessionEventTap, ...)` — globally monitor every key
  press on the system, including events not directed at our window
- `kCGEventTapOptionDefault` (not ListenOnly) — *swallow* the Space key after
  hold threshold so other apps don't see it
- Wait for the chord key, look up binding, launch / activate target app

This requires Accessibility (TCC) permission. Sandbox technically lets the tap
attach, but App Review treats the API as suspect.

### Policy layer — App Review

App Review guidelines (2.5.4 / 4.0 / 5.1.1) reject sandboxed apps that
**globally monitor or intercept keyboard input outside their own windows**,
including: global hotkey hijackers, key remappers, anything that looks like a
keylogger.

The reasoning is privacy and security — Apple wants this class of tool to ship
through Developer ID so users see a clear "you're installing something that
listens to your keyboard" gate, not bundled inside MAS apps.

### Comparable tools and where they ship

| Tool | App Store | Direct (Developer ID) |
|---|---|---|
| Karabiner-Elements (key remapper) | — | only channel |
| Rectangle **Pro** (window mgmt) | crippled version | full version on website |
| BetterTouchTool | never shipped | only channel |
| Hammerspoon / Keyboard Maestro | never shipped | only channel |
| Magnet | full version | — |

Magnet is the exception that proves the rule: it doesn't use `CGEventTap`. It
uses `RegisterEventHotKey`, which is a *registration* API — you tell macOS "I
want ⌘⌥→", the system delivers it to you, you never see other keys. That's
sandbox-friendly because it isn't surveillance.

### Why we can't use `RegisterEventHotKey` instead

`RegisterEventHotKey` only supports modifier-key combos (⌘/⌥/⌃/⇧ + letter).
Space Shortcut's "hold Space then tap a key" interaction is fundamentally a
non-modifier chord, so the API can't express it. The hold-and-chord UX is the
product — replacing it with ⌃⌥+X combos would be a different feature.

So **the only way Space Shortcut works is `CGEventTap`, and the only way
`CGEventTap` ships is outside the App Store**.

## Current implementation

`AppDelegate.applicationDidFinishLaunching` skips registering the feature when
running sandboxed:

```swift
if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
    registry.register(SpaceShortcutFeature())
}
```

`APP_SANDBOX_CONTAINER_ID` is set by macOS only inside a sandboxed process, so
the runtime check is reliable across Debug/Release without needing a separate
build config today.

The feature's source files (`Features/SpaceShortcut/*`) stay in the project —
deleting them now would make the future Developer ID build harder.

## Future: dual-track distribution

When/if Space Shortcut needs to ship to users, run **two builds from one
source**:

| | App Store build | Developer ID build |
|---|---|---|
| Sandbox | on | off |
| Hardened Runtime | on | on |
| Notarization | n/a (App Store handles it) | required |
| Distribution | Mac App Store | website download (DMG/PKG) |
| IAP / tip jar | StoreKit | (Stripe / Paddle / Gumroad / etc.) |
| Auto-update | App Store | Sparkle framework |
| Space Shortcut | disabled | enabled |
| Other CGEventTap features | disabled | enabled |

Examples of products on this model: **Bartender**, **CleanMyMac**,
**Things** (Cultured Code), **Tot**.

### Mechanics when we're ready

1. Add a new Xcode build configuration (e.g. `Release-DeveloperID`) alongside
   `Release`.
2. Two `.entitlements` files:
   - `CapyBuddy.entitlements` — sandbox on (current file, used by App Store)
   - `CapyBuddy-DeveloperID.entitlements` — sandbox off, plus
     `com.apple.security.cs.disable-library-validation` if needed
3. Two schemes, each pinned to one config: `CapyBuddy (App Store)` and
   `CapyBuddy (Developer ID)`.
4. Replace the runtime sandbox check with a compile-time flag (Swift active
   compilation conditions: `APP_STORE` vs `DEVELOPER_ID`) so feature gating is
   explicit:
   ```swift
   #if !APP_STORE
   registry.register(SpaceShortcutFeature())
   #endif
   ```
5. Add a Sparkle XPC framework + appcast feed for Developer ID auto-update
   (App Store build skips Sparkle).
6. CI builds both configurations; release pipeline uploads App Store build to
   App Store Connect and ships notarized DMG of Developer ID build to the
   website.

### What to verify before going dual-track

- IAP receipt validation only works on App Store builds; Developer ID build
  needs a separate licensing system (or just be free / one-price upfront).
- Some entitlements differ. The Developer ID build doesn't need
  `network.client` to be a hard requirement, but it does need Hardened Runtime
  exceptions for any non-Apple-signed dylibs.
- Bundle ID can stay the same (`com.atlai.CapyBuddy`) for both, OR you split into
  `com.atlai.CapyBuddy` (MAS) and `com.atlai.CapyBuddy.pro` (DevID) if you want to price
  them differently.

## Decision log

- **2026-05-08** — Choosing App Store as the primary channel. Space Shortcut
  dropped from this build via runtime sandbox check. Dual-track deferred until
  there's actual demand for the full feature set on a non-MAS channel.
