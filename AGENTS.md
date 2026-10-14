# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build Commands

```bash
make setup      # First-time setup: install mise tools, tuist install, tuist generate
make generate   # Regenerate Xcode project after changing Project.swift
make clean      # Clean Tuist build artifacts
```

The `.xcodeproj` is not committed. Always run `make generate` after modifying `Project.swift`.

## Xcode MCP and DeviceHub Workflow

- Unless the user explicitly requests another workflow, use the Xcode-provided MCP tools for project discovery, building, installation, launching, testing, log capture, and debugging.
- Use the existing devices managed by DeviceHub. Prefer a Simulator that is already booted in DeviceHub; switch to another device only when the user explicitly specifies one or the booted device cannot satisfy the task.
- A request to compile, deploy, run, test, reproduce, or debug this project authorizes using Xcode MCP with an existing DeviceHub device for the complete workflow.
- Reuse existing DeviceHub devices. Do not create, clone, or require a new disposable Simulator unless the user specifically asks for one, and do not pause to ask about Simulator selection when an appropriate booted device is available.
- Do not perform or request routine code-signing, entitlement, app-data backup, or App Group container backup checks before installing or running through Xcode MCP unless the user specifically asks for those checks. Do not repeatedly warn about signing or backups during normal iterations.
- For DeviceHub UI automation, always use `axe describe-ui --udid <UDID>` to read the accessibility hierarchy and UI elements.
- Always use `axe tap --udid <UDID> ...` for UI click/tap operations.
- Always use `axe screenshot --udid <UDID> --output <PATH>` for Simulator screenshots.
- Do not try Xcode MCP UI snapshot or screenshot tools before AXe unless the user explicitly requests them; Xcode MCP remains the default for building, installing, launching, testing, logs, and debugging.
- Xcode 27 does not include `SimulatorKit.framework`; do not treat that as an incomplete installation. Use AXe for DeviceHub UI inspection and interaction.
- Use direct `xcodebuild`, `simctl`, `devicectl`, or manual Xcode operation only as a fallback when the required Xcode MCP capability is unavailable.
- For physical-device deployment, use XcodeBuildMCP, including its `xcodebuildmcp device` CLI when needed.
- Do not erase, reset, or delete an existing device or its containers unless the user explicitly requests that destructive operation.

## Tests

Only the `CookedHTML` package has tests. There are no app-level tests.

```bash
cd Packages/CookedHTML && swift test
```

## WhatToTest

- `TestFlight/WhatToTest.en-US.txt` and `TestFlight/WhatToTest.zh-Hans.txt` are user-facing TestFlight notes, not internal change logs.
- Include only behavior users can observe and useful steps they can perform to verify it.
- Do not include unrelated changes, implementation details, class or file names, internal tooling, build steps, or developer-only diagnostics.
- Keep the English and Simplified Chinese versions aligned in meaning and natural in each language.

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
