//
//  SearchResult.swift
//  Privducai
//
//  Created by Claude on 23/03/2026.
//

import Foundation

struct SearchResult: Identifiable, Codable {
    let id: UUID
    let title: String
    let url: String
    let snippet: String

    init(id: UUID = UUID(), title: String, url: String, snippet: String) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

struct SearchResponse: Codable {
    let results: [SearchResult]
    let query: String
    let timestamp: Date
}
