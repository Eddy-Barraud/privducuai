# SilicIA Project Guidelines

## Code Style
- Keep business logic in `SilicIA/Services/` and keep views in `SilicIA/Views/` focused on UI/state wiring.
- Prefer `@MainActor` service types plus `ObservableObject` + `@Published` for UI-facing async state, matching `AIService` and `ChatService`.
- Keep platform-specific code behind conditional compilation (`#if os(macOS)`, `#elseif canImport(UIKit)`).
- Reuse shared utilities before adding new constants or heuristics, especially `TokenBudgeting` for token/character budgeting.
- Preserve bilingual behavior: any model-facing prompt or user-facing model instruction must support both English and French.

## Architecture
- Project structure is intentionally layered:
  - Models: `SilicIA/Models/` (`AppSettings`, `Conversation`, `Message`, `SearchResult`)
  - Services: `SilicIA/Services/` (search, scraping, RAG context, prompt loading, generation orchestration)
  - Views: `SilicIA/Views/` plus `SilicIA/ContentView.swift`
- Prompt loading is centralized in `SilicIA/Services/PromptLoader.swift`; prompt assets live in `SilicIA/prompts/` with mode/feature/language naming.
- Chat persistence uses SwiftData models (`Conversation` and `Message`) and should remain local-first.

## Build And Validation
- Fast local build: `./scripts/build.sh Debug`
- Build and launch: `./scripts/build-and-run.sh Debug`
- VS Code task default: `xcode: Build (Debug)`
- Manual CI-equivalent build command:
  - `xcodebuild -project SilicIA.xcodeproj -scheme SilicIA -configuration Debug -destination "generic/platform=macOS" build`
- There is currently no dedicated automated unit-test suite in this repo; validate changes by building both Debug and Release configurations.

## Project Conventions And Gotchas
- Treat token allocation as a cross-cutting concern:
  - `maxResponseTokens` can reduce available RAG context because both compete within a fixed context window.
  - When changing response/context behavior, update `TokenBudgeting` and call sites together.
- Keep settings migration logic backward compatible in `AppSettings` (legacy keys are intentionally decoded).
- PDF chat context must reset cleanly across conversation changes (clear both conversation state and loaded PDF UI state).
- After app icon source changes, regenerate icon assets with `logo/convert.sh`.
- Widget plist is hand-authored (`SilicIAWidget/Info.plist`); required bundle keys must remain present.

## Documentation Map
- Architecture and feature overview: [README.md](../README.md)
- Build methods and commands: [BUILDING.md](../BUILDING.md)
- Contribution workflow and conventions: [CONTRIBUTING.md](../CONTRIBUTING.md)
- GitHub workflow/helper details: [GITHUB_AGENT.md](../GITHUB_AGENT.md)
- Product messaging and store copy: [app-short-description.md](../app-short-description.md)
