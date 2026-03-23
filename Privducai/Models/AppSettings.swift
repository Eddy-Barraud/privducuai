//
//  AppSettings.swift
//  Privducai
//
//  Created by Claude on 23/03/2026.
//

import Foundation

struct AppSettings {
    var maxSearchResults: Int = 4
    var maxResponseTokens: Int = 1000
    var temperature: Double = 0.3
    var maxScrapingCharacters: Int = 3000

    // Value ranges for validation
    static let maxSearchResultsRange = 3...20
    static let maxResponseTokensRange = 500...3000
    static let temperatureRange = 0.0...1.0
    static let maxScrapingCharactersRange = 1000...10000
}
