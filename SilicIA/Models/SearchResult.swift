//
//  SearchResult.swift
//  Privducai
//
//  Created by Claude on 23/03/2026.
//

import Foundation

/// Represents one web search result returned by the search provider.
struct SearchResult: Identifiable, Codable {
    let id: UUID
    let title: String
    let url: String
    let snippet: String

    /// Creates a search result with title, URL and snippet metadata.
    init(id: UUID = UUID(), title: String, url: String, snippet: String) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Wraps a full search response payload with metadata.
struct SearchResponse: Codable {
    let results: [SearchResult]
    let query: String
    let timestamp: Date
}
