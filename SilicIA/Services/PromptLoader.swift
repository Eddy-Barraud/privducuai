//
//  PromptLoader.swift
//  SilicIA
//
//  Created by Copilot on 29/03/2026.
//

import Foundation

struct PromptLoader {
    static func languageCode(for language: ModelLanguage) -> String {
        switch language {
        case .french:
            return "fr"
        case .english:
            return "en"
        }
    }

    static func loadPrompt(
        mode: String,
        feature: String,
        variant: String? = nil,
        language: ModelLanguage,
        replacements: [String: String] = [:]
    ) -> String? {
        let languageCode = languageCode(for: language)
        let names: [String]
        if let variant, !variant.isEmpty {
            names = [
                "prompt.\(mode).\(feature).\(variant).\(languageCode)",
                "prompt.\(mode).\(feature).\(languageCode)"
            ]
        } else {
            names = ["prompt.\(mode).\(feature).\(languageCode)"]
        }

        for name in names {
            if let raw = loadPrompt(named: name) {
                return applyReplacements(in: raw, replacements: replacements)
            }
        }

        return nil
    }

    private static func loadPrompt(named name: String) -> String? {
        let candidateURLs: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "prompts"),
            Bundle.main.url(forResource: name, withExtension: "txt")
        ]

        for url in candidateURLs.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               var prompt = String(data: data, encoding: .utf8) {
                if prompt.hasSuffix("\n") {
                    prompt = String(prompt.dropLast())
                }
                return prompt
            }
        }

        return nil
    }

    private static func applyReplacements(in raw: String, replacements: [String: String]) -> String {
        replacements.reduce(raw) { partial, entry in
            partial.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
        }
    }
}
