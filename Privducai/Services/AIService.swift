//
//  AIService.swift
//  Privducai
//
//  Created by Claude on 23/03/2026.
//

import Foundation
import Combine
import NaturalLanguage
import FoundationModels

@MainActor
class AIService: ObservableObject {
    @Published var isSummarizing = false
    @Published var summary: String = ""

    private let webScraper = WebScrapingService()
    private var languageSession: LanguageModelSession?

    /// Summarize search results using Foundation Models or fallback to NLP
    func summarize(query: String, results: [SearchResult], maxScrapingResults: Int = 10, maxScrapingChars: Int = 5000, temperature: Double = 0.3, maxTokens: Int = 1000) async -> String {
        isSummarizing = true
        defer { isSummarizing = false }

        // Scrape content from top pages
        let urls = results.map { $0.url }
        let scrapedContent = await webScraper.scrapeMultiplePages(urls: urls, limit: maxScrapingResults, maxCharacters: maxScrapingChars)

        // Combine scraped content with snippets
        var contextParts: [String] = []

        for result in results {
            if let pageContent = scrapedContent[result.url] {
                contextParts.append("Source: \(result.title)\nURL: \(result.url)\nContent: \(pageContent)")
            } else {
                contextParts.append("Source: \(result.title)\nURL: \(result.url)\nSnippet: \(result.snippet)")
            }
        }

        let fullContext = contextParts.joined(separator: "\n\n---\n\n")

        // Try Foundation Models first, fallback to NLP if it fails
        let summary = await generateSummaryWithFoundationModels(query: query, context: fullContext, results: results, temperature: temperature, maxTokens: maxTokens)

        self.summary = summary
        return summary
    }

    /// Generate summary using Apple Foundation Models
    private func generateSummaryWithFoundationModels(query: String, context: String, results: [SearchResult], temperature: Double = 0.3, maxTokens: Int = 1000) async -> String {
        do {
            // Create session with instructions if we don't have one
            if languageSession == nil {
                let instructions = """
                You are a helpful AI assistant that provides concise, accurate summaries of web search results.
                Your task is to analyze the provided web content and generate a clear, informative summary that directly answers the user's query.

                Guidelines:
                - Be concise but comprehensive
                - Focus on the most relevant information
                - Include key facts and details
                - Maintain accuracy
                - Use clear, easy-to-understand language
                """

                languageSession = LanguageModelSession(instructions: instructions)
            }

            guard let session = languageSession else {
                return await generateConciseSummary(query: query, context: context, results: results)
            }

            // Prepare the prompt
            let prompt = """
            User Query: \(query)

            Web Content:
            \(context)

            Please provide a concise summary that answers the user's query based on the above web content. Structure your response with:
            1. A direct answer to the query
            2. Key supporting details
            3. Any important context or caveats

            Keep the summary under 300 words.
            """

            // Configure generation options
            let options = GenerationOptions(
                temperature: temperature,
                maximumResponseTokens: maxTokens
            )

            // Generate the summary
            let response = try await session.respond(to: prompt, options: options)
            let txt_response = String(describing: response.content)

            // Add source links
            var finalSummary = txt_response + "\n\n**Sources:**\n"
            for (index, result) in results.prefix(5).enumerated() {
                finalSummary += "\(index + 1). [\(result.title)](\(result.url))\n"
            }

            return finalSummary
        } catch {
            print("⚠️ Error generating summary with Foundation Models: \(error.localizedDescription)")
            // Fallback to basic summarization
            return await generateConciseSummary(query: query, context: context, results: results)
        }
    }

    /// Generate a concise summary with links
    private func generateConciseSummary(query: String, context: String, results: [SearchResult]) async -> String {
        // For M3 MacBooks without full Apple Intelligence, we'll create an efficient
        // extractive summary that highlights key information

        // Split context into sentences
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = context

        var sentences: [(sentence: String, score: Double)] = []
        tokenizer.enumerateTokens(in: context.startIndex..<context.endIndex) { range, _ in
            let sentence = String(context[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                // Score sentence based on query relevance
                let score = calculateRelevanceScore(sentence: sentence, query: query)
                sentences.append((sentence, score))
            }
            return true
        }

        // Sort by relevance and take top sentences
        let topSentences = sentences
            .sorted { $0.score > $1.score }
            .prefix(4)
            .map { $0.sentence }

        // Build summary
        var summaryParts: [String] = []

        // Add query context
        summaryParts.append("Based on your search for '\(query)':")
        summaryParts.append("")

        // Add key findings
        if !topSentences.isEmpty {
            summaryParts.append("**Key Findings:**")
            for (index, sentence) in topSentences.enumerated() {
                // Clean up the sentence
                let cleaned = sentence
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !cleaned.isEmpty {
                    summaryParts.append("• \(cleaned)")
                }
            }
            summaryParts.append("")
        }

        // Add top sources with links
        summaryParts.append("**Top Sources:**")
        for (index, result) in results.prefix(5).enumerated() {
            summaryParts.append("\(index + 1). [\(result.title)](\(result.url))")
        }

        return summaryParts.joined(separator: "\n")
    }

    /// Calculate relevance score for a sentence based on query terms
    private func calculateRelevanceScore(sentence: String, query: String) -> Double {
        let sentenceLower = sentence.lowercased()
        let queryWords = query.lowercased().components(separatedBy: .whitespacesAndNewlines)

        var score = 0.0

        // Check for query word matches
        for word in queryWords where word.count > 2 {
            if sentenceLower.contains(word) {
                score += 1.0
            }
        }

        // Bonus for sentence length (prefer informative sentences)
        let wordCount = sentence.components(separatedBy: .whitespacesAndNewlines).count
        if wordCount > 5 && wordCount < 30 {
            score += 0.5
        }

        // Extract key terms using NaturalLanguage
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence

        var hasImportantTerms = false
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex,
                           unit: .word,
                           scheme: .lexicalClass) { tag, _ in
            if tag == .noun || tag == .verb {
                hasImportantTerms = true
                return false
            }
            return true
        }

        if hasImportantTerms {
            score += 0.3
        }

        return score
    }

    /// Generate a quick answer for common query types
    func generateQuickAnswer(query: String, results: [SearchResult]) -> String? {
        let queryLower = query.lowercased()

        // Handle definition queries
        if queryLower.hasPrefix("what is ") || queryLower.hasPrefix("define ") {
            if let firstResult = results.first {
                return "**Quick Answer:** \(firstResult.snippet)\n\n[Source: \(firstResult.title)](\(firstResult.url))"
            }
        }

        // Handle how-to queries
        if queryLower.hasPrefix("how to ") || queryLower.hasPrefix("how do i ") {
            if let firstResult = results.first {
                return "**Quick Guide:** \(firstResult.snippet)\n\n[Full instructions: \(firstResult.title)](\(firstResult.url))"
            }
        }

        return nil
    }
}

