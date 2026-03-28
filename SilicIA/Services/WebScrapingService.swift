//
//  WebScrapingService.swift
//  Privducai
//
//  Created by Claude on 23/03/2026.
//

import Foundation
import Combine

@MainActor
/// Fetches and extracts readable text content from web pages.
class WebScrapingService: ObservableObject {
    @Published var isScrapingContent = false

    private let session: URLSession

    /// Creates a scraping session configured for resilient low-overhead requests.
    init() {
        // Configure URLSession for efficient scraping
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }

    /// Scrape content from a single URL
    func scrapeContent(from urlString: String, maxCharacters: Int = 5000) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

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

        let limitedURLs = Array(urls.prefix(limit))
        var results: [String: String] = [:]

        await withTaskGroup(of: (String, String?).self) { group in
            for url in limitedURLs {
                group.addTask {
                    let content = await self.scrapeContent(from: url, maxCharacters: maxCharacters)
                    return (url, content)
                }
            }

            for await (url, content) in group {
                if let content = content {
                    results[url] = content
                }
            }
        }

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
