//
//  WebSearchService.swift
//  SilicIA
//
//  Created by Claude on 23/03/2026.
//

import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// Strip HTML tags and decode common HTML entities from a raw HTML string.
private func htmlToPlainText(_ html: String) -> String {
    var result = html
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
    }

    let entities: [(String, String)] = [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#x27;", "'"),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&mdash;", "-"),
        ("&ndash;", "-"),
        ("&hellip;", "..."),
        ("&laquo;", "\""),
        ("&raquo;", "\"")
    ]
    for (entity, char) in entities {
        result = result.replacingOccurrences(of: entity, with: char)
    }

    if let numericRegex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
        let matches = numericRegex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()
        for match in matches {
            if let range = Range(match.range(at: 1), in: result),
               let codePoint = Int(result[range]),
               let scalar = Unicode.Scalar(codePoint),
               let fullRange = Range(match.range, in: result) {
                result = result.replacingCharacters(in: fullRange, with: String(scalar))
            }
        }
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Extract the inner HTML for the first element matching a class name and tag.
private func extractInnerHTML(in html: String, className: String, tagName: String) -> String? {
    let escapedClassName = NSRegularExpression.escapedPattern(for: className)
    let escapedTagName = NSRegularExpression.escapedPattern(for: tagName)
    let pattern = "<\(escapedTagName)[^>]*class=\"[^\"]*\\b\(escapedClassName)\\b[^\"]*\"[^>]*>([\\s\\S]*?)</\(escapedTagName)>"

    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(html.startIndex..., in: html)
    guard let match = regex.firstMatch(in: html, options: [], range: range),
          let contentRange = Range(match.range(at: 1), in: html) else {
        return nil
    }
    return String(html[contentRange])
}

@MainActor
/// Performs multi-provider web search and merges DuckDuckGo with Wikipedia REST results.
class WebSearchService: ObservableObject {
    @Published var isSearching = false
    @Published var error: Error?

    private static let wikipediaSearchLimit = 2

    private static let userAgent: String = {
        let appName = "SilicIA"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #elseif os(watchOS)
        let platform = "watchOS"
        #elseif os(tvOS)
        let platform = "tvOS"
        #elseif os(visionOS)
        let platform = "visionOS"
        #else
        let platform = "AppleOS"
        #endif
        let device = {
            #if os(iOS)
            return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            #elseif os(macOS)
            return "Mac"
            #elseif os(watchOS)
            return "AppleWatch"
            #elseif os(tvOS)
            return "AppleTV"
            #elseif os(visionOS)
            return "visionOS"
            #else
            return "Device"
            #endif
        }()
        let engine = "AppleWebKit/605.1.15"
        let contact = "+https://github.com/Eddy-Barraud/SilicIA/discussions"
        return "\(appName)/\(appVersion) (\(platform); \(device)) \(engine); \(contact)"
    }()

    private static let wikipediaPagePathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let session: URLSession

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[WebSearchService] \(message)")
        #endif
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = true
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }

    /// Search DuckDuckGo and Wikipedia, then merge deduplicated results.
    func search(query: String, maxResults: Int = 10, language: ModelLanguage = .english) async throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        debugLog("single-query search start: query=\(query), limit=\(maxResults), language=\(language.rawValue)")

        isSearching = true
        defer { isSearching = false }

        let results = try await executeSearch(query: query, maxResults: maxResults, language: language)

        debugLog("single-query search done: count=\(results.count)")

        return results
    }

    /// Executes multiple searches and interleaves deduplicated results across queries.
    func search(
        queries: [String],
        maxResultsPerQuery: Int = 10,
        mergedLimit: Int = 10,
        language: ModelLanguage = .english
    ) async throws -> [SearchResult] {
        let normalizedQueries = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedQueries.isEmpty, maxResultsPerQuery > 0, mergedLimit > 0 else {
            debugLog("multi-query search skipped: invalid input")
            return []
        }

        isSearching = true
        defer { isSearching = false }

        var uniqueQueries: [String] = []
        var seenQueryKeys = Set<String>()
        for query in normalizedQueries {
            let key = normalizeQueryKey(query)
            if seenQueryKeys.insert(key).inserted {
                uniqueQueries.append(query)
            }
        }

        debugLog(
            "multi-query search start: input=\(normalizedQueries.count), unique=\(uniqueQueries.count), perQueryLimit=\(maxResultsPerQuery), mergedLimit=\(mergedLimit), language=\(language.rawValue)"
        )

        var perQueryResults: [[SearchResult]] = []
        perQueryResults.reserveCapacity(uniqueQueries.count)
        var failedQueries = 0

        for query in uniqueQueries {
            do {
                let results = try await executeSearch(query: query, maxResults: maxResultsPerQuery, language: language)
                perQueryResults.append(results)
                debugLog("query ok: \(query) => \(results.count) results")
            } catch {
                failedQueries += 1
                debugLog("query failed: \(query) => \(error.localizedDescription)")
            }
        }

        if perQueryResults.isEmpty {
            debugLog("multi-query search failed: all queries failed")
            throw SearchError.networkError
        }

        let merged = mergeInterleavedDeduplicatedResults(perQueryResults, mergedLimit: mergedLimit)

        debugLog(
            "multi-query search done: merged=\(merged.count), failures=\(failedQueries)/\(uniqueQueries.count)"
        )

        return merged
    }

    /// Runs both providers for one query and merges deduplicated results.
    private func executeSearch(query: String, maxResults: Int, language: ModelLanguage) async throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        async let duckDuckGoOutcome: ([SearchResult], Error?) = {
            do {
                let results = try await executeDuckDuckGoSearch(query: query, maxResults: maxResults)
                return (results, nil)
            } catch {
                return ([], error)
            }
        }()

        async let wikipediaOutcome: ([SearchResult], Error?) = {
            do {
                let results = try await executeWikipediaSearch(
                    query: query,
                    language: language,
                    limit: Self.wikipediaSearchLimit
                )
                return (results, nil)
            } catch {
                return ([], error)
            }
        }()

        let (duckDuckGoResults, duckDuckGoError) = await duckDuckGoOutcome
        let (wikipediaResults, wikipediaError) = await wikipediaOutcome

        if let duckDuckGoError {
            debugLog("DuckDuckGo search failed for query=\(query): \(duckDuckGoError.localizedDescription)")
        }
        if let wikipediaError {
            debugLog("Wikipedia search failed for query=\(query): \(wikipediaError.localizedDescription)")
        }

        let mergedProviders = mergeInterleavedDeduplicatedResults(
            [duckDuckGoResults, wikipediaResults],
            mergedLimit: maxResults+Self.wikipediaSearchLimit
        )

        if mergedProviders.isEmpty {
            throw SearchError.networkError
        }

        return mergedProviders
    }

    /// Executes DuckDuckGo HTML search.
    private func executeDuckDuckGoSearch(query: String, maxResults: Int) async throws -> [SearchResult] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://html.duckduckgo.com/html/?q=\(encodedQuery)"

        guard let url = URL(string: urlString) else {
            throw SearchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SearchError.invalidResponse
        }

        let results = try parseDuckDuckGoHTMLResults(from: data)
        return Array(results.prefix(maxResults))
    }

    /// Executes Wikipedia REST search and enriches each page with full source content.
    private func executeWikipediaSearch(query: String, language: ModelLanguage, limit: Int) async throws -> [SearchResult] {
        guard let searchURL = wikipediaSearchURL(query: query, language: language, limit: limit) else {
            throw SearchError.invalidURL
        }

        var request = URLRequest(url: searchURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SearchError.invalidResponse
        }

        let decoded = try Self.jsonDecoder.decode(WikipediaSearchResponse.self, from: data)
        let pages = Array(decoded.pages.prefix(max(limit, 0)))
        guard !pages.isEmpty else { return [] }

        let detailsByKey = await fetchWikipediaPageDetailsByKey(
            keys: pages.map(\.key),
            language: language
        )

        return pages.compactMap { page in
            let details = detailsByKey[page.key]
            let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippetCandidate = htmlToPlainText(page.excerpt ?? page.description ?? "")
            let snippet = snippetCandidate.isEmpty ? "Wikipedia page" : snippetCandidate
            let pageURL = details?.contentUrls?.desktop?.page?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? details?.htmlUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? wikipediaReadablePageURL(for: page.key, language: language)
            let retrievedContent = details?.source?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !pageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return SearchResult(
                title: title.isEmpty ? page.key.replacingOccurrences(of: "_", with: " ") : title,
                url: pageURL,
                snippet: snippet,
                retrievedContent: retrievedContent?.isEmpty == true ? nil : retrievedContent
            )
        }
    }

    /// Fetches Wikipedia page details (including full source text) for each page key.
    private func fetchWikipediaPageDetailsByKey(keys: [String], language: ModelLanguage) async -> [String: WikipediaPageResponse] {
        var uniqueKeys: [String] = []
        var seenKeys = Set<String>()
        for key in keys where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if seenKeys.insert(key).inserted {
                uniqueKeys.append(key)
            }
        }

        guard !uniqueKeys.isEmpty else { return [:] }

        var detailsByKey: [String: WikipediaPageResponse] = [:]
        await withTaskGroup(of: (String, WikipediaPageResponse?).self) { group in
            for key in uniqueKeys {
                group.addTask {
                    let page = await self.fetchWikipediaPageDetails(for: key, language: language)
                    return (key, page)
                }
            }

            for await (key, page) in group {
                if let page {
                    detailsByKey[key] = page
                }
            }
        }

        return detailsByKey
    }

    /// Calls /w/rest.php/v1/page/[key] and decodes full page source content.
    private func fetchWikipediaPageDetails(for key: String, language: ModelLanguage) async -> WikipediaPageResponse? {
        guard let pageURL = wikipediaPageEndpointURL(key: key, language: language) else {
            return nil
        }

        do {
            var request = URLRequest(url: pageURL)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            return try Self.jsonDecoder.decode(WikipediaPageResponse.self, from: data)
        } catch {
            debugLog("Wikipedia page fetch failed for key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    /// Interleaves result lists, removing duplicate URLs, up to the provided limit.
    private func mergeInterleavedDeduplicatedResults(
        _ perQueryResults: [[SearchResult]],
        mergedLimit: Int
    ) -> [SearchResult] {
        guard mergedLimit > 0 else { return [] }

        var merged: [SearchResult] = []
        merged.reserveCapacity(mergedLimit)

        var seenURLKeys = Set<String>()
        var index = 0

        while merged.count < mergedLimit {
            var addedInRound = false

            for queryResults in perQueryResults where index < queryResults.count {
                let candidate = queryResults[index]
                let urlKey = normalizeURLKey(candidate.url)
                if seenURLKeys.insert(urlKey).inserted {
                    merged.append(candidate)
                    addedInRound = true
                    if merged.count == mergedLimit {
                        break
                    }
                }
            }

            if perQueryResults.allSatisfy({ index >= $0.count - 1 }) {
                break
            }
            if !addedInRound && perQueryResults.allSatisfy({ index >= $0.count }) {
                break
            }

            index += 1
        }

        return merged
    }

    /// Normalizes a query to support case-insensitive deduplication.
    private func normalizeQueryKey(_ query: String) -> String {
        query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes URLs for deduplication while preserving path/query specificity.
    private func normalizeURLKey(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else {
            return rawURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        components.fragment = nil
        let scheme = (components.scheme ?? "https").lowercased()
        let host = (components.host ?? "").lowercased()
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return "\(scheme)://\(host)\(path)\(query)"
    }

    /// Parse DuckDuckGo HTML response.
    private func parseDuckDuckGoHTMLResults(from data: Data) throws -> [SearchResult] {
        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.parsingFailed
        }

        var results: [SearchResult] = []
        let components = html.components(separatedBy: "class=\"result__a\"")

        for i in 1..<min(components.count, 21) {
            let component = components[i]

            guard let hrefRange = component.range(of: "href=\""),
                  let hrefEndRange = component.range(of: "\"", range: hrefRange.upperBound..<component.endIndex) else {
                continue
            }
            let url = String(component[hrefRange.upperBound..<hrefEndRange.lowerBound])

            guard let titleStart = component.range(of: ">"),
                  let titleEnd = component.range(of: "</a>", range: titleStart.upperBound..<component.endIndex) else {
                continue
            }
            let title = htmlToPlainText(String(component[titleStart.upperBound..<titleEnd.lowerBound]))

            let snippetHTML = extractInnerHTML(in: component, className: "result__snippet", tagName: "a")
                ?? extractInnerHTML(in: component, className: "result__snippet", tagName: "div")
                ?? ""
            let snippet = htmlToPlainText(snippetHTML)

            let cleanURL = url.hasPrefix("//duckduckgo.com/l/?") ? extractActualURL(from: url) : url

            results.append(SearchResult(
                title: title.isEmpty ? "Result \(i)" : title,
                url: cleanURL,
                snippet: snippet.isEmpty ? "No description available" : snippet
            ))
        }

        return results
    }

    /// Extract actual URL from DuckDuckGo redirect.
    private func extractActualURL(from ddgURL: String) -> String {
        guard let uddParam = ddgURL.components(separatedBy: "uddg=").last,
              let actualURL = uddParam.components(separatedBy: "&").first,
              let decoded = actualURL.removingPercentEncoding else {
            return ddgURL
        }
        return decoded
    }

    private func wikipediaSearchURL(query: String, language: ModelLanguage, limit: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = wikipediaHost(for: language)
        components.path = "/w/rest.php/v1/search/page"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "\(max(1, limit))")
        ]
        return components.url
    }

    private func wikipediaPageEndpointURL(key: String, language: ModelLanguage) -> URL? {
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.wikipediaPagePathAllowed) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = wikipediaHost(for: language)
        components.path = "/w/rest.php/v1/page/\(encodedKey)"
        return components.url
    }

    private func wikipediaReadablePageURL(for key: String, language: ModelLanguage) -> String {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.wikipediaPagePathAllowed) ?? key
        return "https://\(wikipediaHost(for: language))/wiki/\(encodedKey)"
    }

    private func wikipediaHost(for language: ModelLanguage) -> String {
        language == .french ? "fr.wikipedia.org" : "en.wikipedia.org"
    }
}

private struct WikipediaSearchResponse: Decodable {
    let pages: [WikipediaSearchPage]
}

private struct WikipediaSearchPage: Decodable {
    let key: String
    let title: String
    let excerpt: String?
    let description: String?
}

private struct WikipediaPageResponse: Decodable {
    struct ContentURLs: Decodable {
        struct Desktop: Decodable {
            let page: String?
        }

        let desktop: Desktop?
    }

    let key: String
    let title: String?
    let source: String?
    let contentUrls: ContentURLs?
    let htmlUrl: String?
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
