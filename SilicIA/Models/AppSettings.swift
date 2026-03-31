//
//  AppSettings.swift
//  SilicIA
//
//  Created by Claude on 23/03/2026.
//

import Foundation

/// Supported output languages for generated model responses.
enum ModelLanguage: String, CaseIterable, Codable {
    case french = "French"
    case english = "English"
}

/// User-configurable settings controlling search and summary behavior.
struct AppSettings: Codable, Equatable {
    var maxSearchResults: Int = 5
    var maxResponseTokens: Int = 2000
    var temperature: Double = 0.3
    var maxContextTokens: Int = 3500
    var language: ModelLanguage = .english

    private static let storageKey = "SilicIA.AppSettings"
    private static let defaultSettings = AppSettings()

    private enum CodingKeys: String, CodingKey {
        case maxSearchResults
        case maxResponseTokens
        case temperature
        case maxContextTokens
        case language
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case maxContextWords
        case maxScrapingCharacters
    }

    init() {}

    /// Loads settings from UserDefaults and falls back to defaults if unavailable.
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return AppSettings().normalized()
        }

        do {
            return try JSONDecoder().decode(AppSettings.self, from: data).normalized()
        } catch {
            return AppSettings().normalized()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        maxSearchResults = try container.decodeIfPresent(Int.self, forKey: .maxSearchResults)
            ?? Self.defaultSettings.maxSearchResults
        maxResponseTokens = try container.decodeIfPresent(Int.self, forKey: .maxResponseTokens)
            ?? Self.defaultSettings.maxResponseTokens
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            ?? Self.defaultSettings.temperature
        language = try container.decodeIfPresent(ModelLanguage.self, forKey: .language)
            ?? Self.defaultSettings.language

        if let storedContextTokens = try container.decodeIfPresent(Int.self, forKey: .maxContextTokens) {
            maxContextTokens = storedContextTokens
        } else if let storedContextWords = try legacyContainer.decodeIfPresent(Int.self, forKey: .maxContextWords) {
            maxContextTokens = max(1, TokenBudgeting.estimatedTokens(forApproxWords: storedContextWords))
        } else if let legacyScrapeCharacters = try legacyContainer.decodeIfPresent(Int.self, forKey: .maxScrapingCharacters) {
            // Preserve user intent from older builds where context was configured in characters.
            maxContextTokens = max(1, legacyScrapeCharacters / TokenBudgeting.avgCharsPerToken)
        } else {
            maxContextTokens = Self.defaultSettings.maxContextTokens
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxSearchResults, forKey: .maxSearchResults)
        try container.encode(maxResponseTokens, forKey: .maxResponseTokens)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxContextTokens, forKey: .maxContextTokens)
        try container.encode(language, forKey: .language)
    }

    /// Persists settings in UserDefaults for future launches.
    func save() {
        do {
            let data = try JSONEncoder().encode(normalized())
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            #if DEBUG
            print("[AppSettings] Failed to save settings: \(error)")
            #endif
        }
    }

    // Value ranges for validation
    static let maxSearchResultsRange = 1...30
    static let maxResponseTokensRange = 500...3500
    static let temperatureRange = 0.3...1.0
    static let maxContextTokensRange = 300...3500

    private func normalized() -> AppSettings {
        var copy = self
        copy.maxSearchResults = min(max(copy.maxSearchResults, Self.maxSearchResultsRange.lowerBound), Self.maxSearchResultsRange.upperBound)
        copy.maxResponseTokens = min(max(copy.maxResponseTokens, Self.maxResponseTokensRange.lowerBound), Self.maxResponseTokensRange.upperBound)
        copy.maxContextTokens = min(max(copy.maxContextTokens, Self.maxContextTokensRange.lowerBound), Self.maxContextTokensRange.upperBound)
        copy.temperature = min(max(copy.temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound)
        return copy
    }
}
