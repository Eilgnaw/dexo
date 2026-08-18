# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build Commands

```bash
make setup      # First-time setup: install mise tools, tuist install, tuist generate
make generate   # Regenerate Xcode project after changing Project.swift
make clean      # Clean Tuist build artifacts
```

The `.xcodeproj` is not committed. Always run `make generate` after modifying `Project.swift`.

## Tests

Only the `CookedHTML` package has tests. There are no app-level tests.

```bash
cd Packages/CookedHTML && swift test
```

## Architecture

Dexo is a native iOS Discourse forum client (UIKit, iOS 15+). No SwiftUI.

**MVVM with `@Observable`**
- ViewModels use Swift 5.9 `@Observable` macro
- ViewControllers subclass `ObservableViewController`, which drives UI updates via a recursive `withObservationTracking { updateUI() }` loop started in `viewWillAppear`
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` applies project-wide

**Key layers:**
- `dexo/Networking/` — `DiscourseAPI` (one instance per forum, Alamofire-based) + `DiscourseRouter` (all API routes as enum)
- `dexo/Core/Auth/` — Discourse User API Key OAuth flow via `ASWebAuthenticationSession` + RSA key pair in Keychain
- `dexo/Database/` — GRDB `DatabasePool` with versioned migrations, stores `ForumInstance` records
- `dexo/Core/Settings/` — `AppSettings` (`@Observable` singleton) for user preferences
- `Packages/CookedHTML/` — Local Swift package for parsing Discourse-cooked HTML into `BlockNode`/`InlineNode` trees, with `NSAttributedString` rendering support

**Topic rendering** is fully native — posts go through the UIKit block renderers under `dexo/Features/ForumDetail/TopicDetail/NativeContent/` (one renderer per `ContentBlock` type, all summed into `PostNativeCell`'s content stack). Block heights are precomputed by `BlockHeightCalculator` so `heightForRowAt` doesn't fall back to `systemLayoutSizeFitting`; whenever you change a renderer, mirror the layout math in the calculator's matching case.

## Localization

- Source language: English (`en`); also supports Simplified Chinese (`zh-Hans`)
- Use `String(localized: "key")` for all user-facing strings — never hardcode string literals
- Xcode automatically extracts keys into `dexo/Localizable.xcstrings` at build time (`SWIFT_EMIT_LOC_STRINGS = YES`)
- Add Chinese translations directly in `Localizable.xcstrings`
- When adding or modifying user-facing strings, always provide both English and Chinese translations

## Theming

- Use `ThemeManager.shared` for colors (e.g. `codeBackgroundColor`) — never hardcode colors like `.systemBackground`
- Set theme-dependent colors in display-time methods (`willDisplay()`, `configure()`, `updateUI()`) rather than `init`, so they respond to runtime theme/color changes

## Project Configuration

- Tuist version is pinned in `.mise.toml`
- Development Team ID goes in `.mise.local.toml` (not committed) as `TUIST_DEVELOPMENT_TEAM`
- Dependencies declared in `Tuist/Package.swift`: Alamofire, GRDB, SDWebImage, Lightbox
