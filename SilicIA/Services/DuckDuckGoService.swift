//
//  DuckDuckGoService.swift
//  SilicIA
//
//  Created by Claude on 23/03/2026.
//

import Foundation
import Combine

/// Strip HTML tags and decode common HTML entities from a raw HTML string.
private func htmlToPlainText(_ html: String) -> String {
    // Remove all HTML tags
    var result = html
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
    }
    // Decode HTML entities
    let entities: [(String, String)] = [
        ("&amp;",  "&"),
        ("&lt;",   "<"),
        ("&gt;",   ">"),
        ("&quot;", "\""),
        ("&#x27;", "'"),
        ("&#39;",  "'"),
        ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&hellip;", "…"),
        ("&laquo;", "«"),
        ("&raquo;", "»"),
    ]
    for (entity, char) in entities {
        result = result.replacingOccurrences(of: entity, with: char)
    }
    // Decode numeric decimal entities like &#8230;
    if let numericRegex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
        let matches = numericRegex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()
        for match in matches {
            if let range = Range(match.range(at: 1), in: result),
               let codePoint = Int(result[range]),
               let scalar = Unicode.Scalar(codePoint) {
                let fullRange = Range(match.range, in: result)!
                result = result.replacingCharacters(in: fullRange, with: String(scalar))
            }
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct DuckDuckGoAPIResponse: Decodable {
    let heading: String?
    let abstractText: String?
    let abstractURL: String?
    let results: [DuckDuckGoAPIResult]?
    let relatedTopics: [DuckDuckGoAPITopic]?

    enum CodingKeys: String, CodingKey {
        case heading = "Heading"
        case abstractText = "AbstractText"
        case abstractURL = "AbstractURL"
        case results = "Results"
        case relatedTopics = "RelatedTopics"
    }
}

private struct DuckDuckGoAPIResult: Decodable {
    let firstURL: String?
    let text: String?
    let result: String?

    enum CodingKeys: String, CodingKey {
        case firstURL = "FirstURL"
        case text = "Text"
        case result = "Result"
    }
}

private struct DuckDuckGoAPITopic: Decodable {
    let firstURL: String?
    let text: String?
    let result: String?
    let topics: [DuckDuckGoAPITopic]?

    enum CodingKeys: String, CodingKey {
        case firstURL = "FirstURL"
        case text = "Text"
        case result = "Result"
        case topics = "Topics"
    }
}

@MainActor
/// Performs DuckDuckGo API search and parses result cards.
class DuckDuckGoService: ObservableObject {
    @Published var isSearching = false
    @Published var error: Error?

    private let session: URLSession

    /// Creates a search session configured for efficient DuckDuckGo requests.
    init() {
        // Configure URLSession for efficient power usage
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = true
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }

    /// Search DuckDuckGo using their public Instant Answer API.
    func search(query: String, maxResults: Int = 10) async throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        guard maxResults > 0 else { return [] }

        debugSearch("start queryLength=\(query.count) maxResults=\(maxResults)")
        isSearching = true
        defer { isSearching = false }

        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "0")
        ]

        guard let url = components?.url else {
            throw SearchError.invalidURL
        }
        debugSearch("request url=\(url.absoluteString)")
        
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            debugSearch("invalid non-HTTP response")
            throw SearchError.invalidResponse
        }
        debugSearch("response status=\(httpResponse.statusCode) bytes=\(data.count)")

        guard httpResponse.statusCode == 200 else {
            debugSearch("non-200 payloadSummary=\(debugPayloadSummary(from: data))")
            throw SearchError.invalidResponse
        }

        let results = try parseAPIResults(from: data, query: query, maxResults: maxResults)
        if results.isEmpty {
            debugSearch("no results produced queryLength=\(query.count) payloadSummary=\(debugPayloadSummary(from: data))")
        } else {
            debugSearch("completed resultsCount=\(results.count)")
        }
        return results
    }

    /// Parse DuckDuckGo API response.
    private func parseAPIResults(from data: Data, query: String, maxResults: Int) throws -> [SearchResult] {
        let response: DuckDuckGoAPIResponse
        do {
            response = try JSONDecoder().decode(DuckDuckGoAPIResponse.self, from: data)
        } catch {
            debugSearch("decode failed error=\"\(error.localizedDescription)\" payloadSummary=\(debugPayloadSummary(from: data))")
            throw SearchError.parsingFailed
        }
        debugSearch(
            "decoded headingEmpty=\((response.heading ?? "").isEmpty) " +
            "abstractURLEmpty=\((response.abstractURL ?? "").isEmpty) " +
            "resultsCount=\(response.results?.count ?? 0) " +
            "relatedTopicsCount=\(response.relatedTopics?.count ?? 0)"
        )

        var results: [SearchResult] = []
        var seenURLs = Set<String>()
        var duplicatesFiltered = 0
        var missingURLItems = 0

        func appendResult(title: String, url: String, snippet: String) {
            guard results.count < maxResults else { return }
            let cleanURL = normalizeResultURL(url)
            guard !cleanURL.isEmpty else { return }
            guard seenURLs.insert(cleanURL).inserted else {
                duplicatesFiltered += 1
                return
            }
            results.append(SearchResult(
                title: title.isEmpty ? query : title,
                url: cleanURL,
                snippet: snippet.isEmpty ? "No description available" : snippet
            ))
        }

        if let abstractURL = response.abstractURL, !abstractURL.isEmpty {
            let heading = htmlToPlainText(response.heading ?? "")
            let title = heading.isEmpty ? query : heading
            appendResult(
                title: title,
                url: abstractURL,
                snippet: htmlToPlainText(response.abstractText ?? "")
            )
        }

        for item in response.results ?? [] {
            guard let url = item.firstURL else {
                missingURLItems += 1
                continue
            }
            let (title, snippet) = splitTitleAndSnippet(
                text: item.text ?? item.result ?? "",
                fallbackTitle: query
            )
            appendResult(title: title, url: url, snippet: snippet)
            if results.count >= maxResults { return results }
        }

        func appendTopic(_ topic: DuckDuckGoAPITopic) {
            guard results.count < maxResults else { return }
            if let nested = topic.topics, !nested.isEmpty {
                for subtopic in nested {
                    appendTopic(subtopic)
                    if results.count >= maxResults { return }
                }
                return
            }

            guard let url = topic.firstURL else {
                missingURLItems += 1
                return
            }
            let (title, snippet) = splitTitleAndSnippet(
                text: topic.text ?? topic.result ?? "",
                fallbackTitle: query
            )
            appendResult(title: title, url: url, snippet: snippet)
        }

        for topic in response.relatedTopics ?? [] {
            if results.count >= maxResults { break }
            appendTopic(topic)
        }

        debugSearch(
            "parse summary finalCount=\(results.count) duplicatesFiltered=\(duplicatesFiltered) missingURLItems=\(missingURLItems)"
        )
        return results
    }

    /// Extract actual URL from DuckDuckGo redirect
    private func extractActualURL(from ddgURL: String) -> String {
        guard let uddParam = ddgURL.components(separatedBy: "uddg=").last,
              let actualURL = uddParam.components(separatedBy: "&").first,
              let decoded = actualURL.removingPercentEncoding else {
            return ddgURL
        }
        return decoded
    }

    private func normalizeResultURL(_ urlString: String) -> String {
        var normalized = urlString
        if normalized.hasPrefix("//") {
            normalized = "https:" + normalized
        }
        if normalized.contains("duckduckgo.com/l/?") {
            normalized = extractActualURL(from: normalized)
        }
        return normalized
    }

    private func splitTitleAndSnippet(text: String, fallbackTitle: String) -> (String, String) {
        let cleaned = htmlToPlainText(text)
        guard !cleaned.isEmpty else { return (fallbackTitle, "") }

        // Handle common space-delimited title/snippet separators.
        for separator in [" - ", " — ", " – ", ": "] {
            let parts = cleaned.components(separatedBy: separator)
            if parts.count >= 2 {
                let title = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackTitle
                let snippet = parts.dropFirst().joined(separator: separator)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (title.isEmpty ? fallbackTitle : title, snippet)
            }
        }

        return (cleaned, "")
    }

    /// Summarizes payload shape without logging full content.
    private func debugPayloadSummary(from data: Data) -> String {
        let byteCount = data.count
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return "bytes=\(byteCount) jsonTopLevel=unknown"
        }
        let keys = dictionary.keys.sorted().joined(separator: ",")
        return "bytes=\(byteCount) jsonTopLevelKeys=[\(keys)]"
    }

    /// Emits DuckDuckGo search diagnostics only in DEBUG builds.
    private func debugSearch(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[DuckDuckGoService] \(message())")
        #endif
    }
}

/// Enumerates high-level search failure categories.
enum SearchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case parsingFailed
    case networkError

    /// Provides user-facing descriptions for search errors.
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid search URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .parsingFailed:
            return "Failed to parse search results"
        case .networkError:
            return "Network error occurred"
        }
    }
}
