//
//  SilicIAAppShortcuts.swift
//  SilicIA
//
//  Created by Copilot on 31/03/2026.
//

import AppIntents

/// Registers shortcut phrases so Spotlight can trigger SilicIA search.
struct SilicIAAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSilicIASearchIntent(),
            phrases: [
                "Search with \(.applicationName)",
                "Find with \(.applicationName)"
            ],
            shortTitle: "SilicIA Search",
            systemImageName: "magnifyingglass"
        )
    }
}
