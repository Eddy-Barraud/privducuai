//
//  WebScrapingService.swift
//  SilicIA
//
//  Created by Claude on 23/03/2026.
//

import Foundation
import Combine

@MainActor
/// Fetches and extracts readable text content from web pages.
class WebScrapingService: ObservableObject {
    /// App-specific User-Agent identifying SilicIA. Update version/contact as needed.
    /// Format recommendation: AppName/Version (Platform; Device) Engine; +ContactURL
    private static let userAgent: String = {
        // You can optionally make these dynamic using Bundle info and UIDevice.
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
        // Include WebKit engine hint and a contact URL per good scraping etiquette
        let engine = "AppleWebKit/605.1.15"
        let contact = "+https://github.com/Eddy-Barraud/SilicIA/discussions"
        return "\(appName)/\(appVersion) (\(platform); \(device)) \(engine); \(contact)"
    }()

    @Published var isScrapingContent = false

    #if DEBUG
    struct ScrapeDebugStats {
        let requestedLimit: Int
        let candidateURLCount: Int
        let launchedTasks: Int
        let completedTasks: Int
        let succeededPages: Int
        let canceledTasks: Int
        let poolSize: Int
        let overfetchCount: Int
        let didEarlyCancel: Bool
        let elapsedSeconds: Double
    }

    @Published var lastDebugStats: ScrapeDebugStats?
    #endif

    private let session: URLSession
    private static let scrapeConcurrency = 8
    private static let overfetchCount = 3

    /// Creates a scraping session configured for resilient low-overhead requests.
    init() {
        // Configure URLSession for efficient scraping
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }

    /// Scrape content from a single URL
    func scrapeContent(from urlString: String, maxCharacters: Int = 5000) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            // Extract text content from HTML
            return extractTextFromHTML(html, maxCharacters: maxCharacters)
        } catch {
            return nil
        }
    }

    /// Scrape content from multiple URLs concurrently
    func scrapeMultiplePages(urls: [String], limit: Int = 10, maxCharacters: Int = 5000) async -> [String: String] {
        isScrapingContent = true
        defer { isScrapingContent = false }

        let targetSuccessCount = max(0, limit)
        guard targetSuccessCount > 0 else { return [:] }

        let fetchCount = targetSuccessCount + Self.overfetchCount
        let limitedURLs = Array(urls.prefix(fetchCount))
        var results: [String: String] = [:]
        var urlIterator = limitedURLs.makeIterator()
        let initialWorkers = min(Self.scrapeConcurrency, limitedURLs.count)

        #if DEBUG
        let scrapeStart = Date()
        var launchedTasks = 0
        var completedTasks = 0
        var didEarlyCancel = false
        #endif

        await withTaskGroup(of: (String, String?).self) { group in
            for _ in 0..<initialWorkers {
                guard let nextURL = urlIterator.next() else { break }
                #if DEBUG
                launchedTasks += 1
                #endif
                group.addTask {
                    let content = await self.scrapeContent(from: nextURL, maxCharacters: maxCharacters)
                    return (nextURL, content)
                }
            }

            for await (url, content) in group {
                #if DEBUG
                completedTasks += 1
                #endif

                if let content = content {
                    results[url] = content
                    // Keep the fastest successful pages only.
                    if results.count >= targetSuccessCount {
                        #if DEBUG
                        didEarlyCancel = completedTasks < limitedURLs.count
                        #endif
                        group.cancelAll()
                        break
                    }
                }

                if let nextURL = urlIterator.next() {
                    #if DEBUG
                    launchedTasks += 1
                    #endif
                    group.addTask {
                        let content = await self.scrapeContent(from: nextURL, maxCharacters: maxCharacters)
                        return (nextURL, content)
                    }
                }
            }
        }

        #if DEBUG
        let canceledTasks = max(launchedTasks - completedTasks, 0)
        lastDebugStats = ScrapeDebugStats(
            requestedLimit: targetSuccessCount,
            candidateURLCount: limitedURLs.count,
            launchedTasks: launchedTasks,
            completedTasks: completedTasks,
            succeededPages: results.count,
            canceledTasks: canceledTasks,
            poolSize: Self.scrapeConcurrency,
            overfetchCount: Self.overfetchCount,
            didEarlyCancel: didEarlyCancel,
            elapsedSeconds: Date().timeIntervalSince(scrapeStart)
        )
        #endif

        return results
    }

    /// Extract readable text content from HTML
    private func extractTextFromHTML(_ html: String, maxCharacters: Int = 5000) -> String {
        var text = html

        // Remove script and style tags with their content
        text = removeTagsWithContent(text, tags: ["script", "style", "nav", "header", "footer"])

        // Remove HTML comments
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Decode common HTML entities
        text = decodeHTMLEntities(text)

        // Clean up whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Limit to reasonable size (user-configured max characters to avoid token limits)
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
        }

        return text
    }

    /// Remove specific HTML tags along with their content
    private func removeTagsWithContent(_ html: String, tags: [String]) -> String {
        var result = html
        for tag in tags {
            let pattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    /// Decode common HTML entities
    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…"
        ]

        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        return result
    }
}

