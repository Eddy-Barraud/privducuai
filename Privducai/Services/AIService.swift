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

    // Apple on-device Foundation Models context window (tokens)
    private static let contextWindowLimit = 4096
    // Conservative chars-per-token estimate: French/European text averages ~3 chars per
    // subword token which is more compact than the ~4 chars typical for English.  Using 3
    // ensures we stay within budget for the denser language rather than the sparser one.
    private static let avgCharsPerToken = 3

    /// Summarize search results using Foundation Models or fallback to NLP
    func summarize(query: String, results: [SearchResult], maxScrapingResults: Int = 10, maxScrapingChars: Int = 5000, temperature: Double = 0.3, maxTokens: Int = 1000, language: ModelLanguage = .french) async -> String {
        isSummarizing = true
        defer { isSummarizing = false }

        // Scrape content from top pages
        let urls = results.map { $0.url }
        let scrapedContent = await webScraper.scrapeMultiplePages(urls: urls, limit: maxScrapingResults, maxCharacters: maxScrapingChars)

        // Per-page summarization uses its own small response budget (2-3 sentence summaries).
        // Compute content budget independently from the final-summary maxTokens setting so
        // that a large maxTokens value doesn't unnecessarily shrink per-page content.
        let pageResponseTokens = 150      // tokens reserved for each page summary response
        let pageInstructionTokens = 40    // short per-page session instructions
        let pagePromptOverheadTokens = 60 // query, title, labels in the per-page prompt
        let pageContentAvailableTokens = max(
            0,
            AIService.contextWindowLimit - pageInstructionTokens - pagePromptOverheadTokens - pageResponseTokens
        )
        // Respect the user's maxScrapingChars setting; never exceed the token budget.
        let pageMaxChars = min(maxScrapingChars, pageContentAvailableTokens * AIService.avgCharsPerToken)

        // Summarize each scraped page individually with a fresh session per page,
        // then combine the resulting short summaries for the final AI step.
        var summarizedParts: [String] = []

        for result in results {
            if let pageContent = scrapedContent[result.url] {
                let pageSummary = await summarizePage(
                    content: pageContent,
                    title: result.title,
                    url: result.url,
                    query: query,
                    temperature: temperature,
                    language: language,
                    maxResponseTokens: pageResponseTokens,
                    maxContentChars: pageMaxChars
                )
                summarizedParts.append(pageSummary)
            } else {
                // Use snippet if no full content was scraped
                summarizedParts.append("Source: \(result.title)\nURL: \(result.url)\nSnippet: \(result.snippet)")
            }
        }

        let fullContext = summarizedParts.joined(separator: "\n\n---\n\n")

        // Try Foundation Models first, fallback to NLP if it fails
        let summary = await generateSummaryWithFoundationModels(query: query, context: fullContext, results: results, temperature: temperature, maxTokens: maxTokens, language: language)

        self.summary = summary
        return summary
    }

    /// Generate summary using Apple Foundation Models
    private func generateSummaryWithFoundationModels(query: String, context: String, results: [SearchResult], temperature: Double = 0.3, maxTokens: Int = 1000, language: ModelLanguage = .french) async -> String {
        do {
            // Always create a fresh session so that context from previous searches
            // does not accumulate and overflow the context window.
            let instructions: String

            if language == .french {
                instructions = """
                Vous êtes un assistant IA utile qui fournit des résumés concis et précis des résultats de recherche web.
                Votre tâche est d'analyser le contenu web fourni et de générer un résumé clair et informatif qui répond directement à la requête de l'utilisateur.

                Directives :
                - Soyez concis mais complet
                - Concentrez-vous sur les informations les plus pertinentes
                - Incluez les faits et détails clés
                - Maintenez la précision
                - Utilisez un langage clair et facile à comprendre
                """
            } else {
                instructions = """
                You are a helpful AI assistant that provides concise, accurate summaries of web search results.
                Your task is to analyze the provided web content and generate a clear, informative summary that directly answers the user's query.

                Guidelines:
                - Be concise but comprehensive
                - Focus on the most relevant information
                - Include key facts and details
                - Maintain accuracy
                - Use clear, easy-to-understand language
                """
            }

            let session = LanguageModelSession(instructions: instructions)

            // Token budget for the final summary.
            // Apple on-device Foundation Models have a context window of ~4096 tokens.
            // Tokens consumed by: session instructions (~100), prompt template overhead –
            // query label, section headers, closing instructions (~80), and the response.
            let instructionTokens = 100
            let promptOverheadTokens = 80
            // Ensure maxTokens never crowds out context entirely: reserve at least 300 tokens
            // for the combined page summaries so the model has something to work with.
            let minContextTokens = 300
            let effectiveMaxTokens = min(
                maxTokens,
                AIService.contextWindowLimit - instructionTokens - promptOverheadTokens - minContextTokens
            )
            let reservedTokens = instructionTokens + promptOverheadTokens + effectiveMaxTokens
            // Apply a 20 % utilization buffer on top of the char-per-token estimate to
            // absorb tokeniser variance (French and other languages can be denser than English).
            let utilizationFactor = 0.8
            let availableTokens = max(AIService.contextWindowLimit - reservedTokens, 0)
            let maxContextChars = Int(Double(availableTokens * AIService.avgCharsPerToken) * utilizationFactor)
            
            // If context fits, use it all; otherwise intelligently select summaries
            var selectedContext: String
            if context.count <= maxContextChars {
                selectedContext = context
            } else {
                // Split summaries and include as many as fit within the context window
                let summaryChunks = context.components(separatedBy: "\n\n---\n\n")
                selectedContext = ""
                for chunk in summaryChunks {
                    if (selectedContext + chunk).count <= maxContextChars {
                        if selectedContext.isEmpty {
                            selectedContext = chunk
                        } else {
                            selectedContext += "\n\n---\n\n" + chunk
                        }
                    } else {
                        break
                    }
                }
                
                // If no summaries fit, use at least the first one
                if selectedContext.isEmpty && !summaryChunks.isEmpty {
                    selectedContext = String(summaryChunks[0].prefix(maxContextChars))
                }
            }

            // Prepare the prompt in the selected language
            let prompt: String
            
            if language == .french {
                prompt = """
                Requête de l'utilisateur : \(query)

                Résumés des pages Web :
                \(selectedContext)

                Veuillez fournir un résumé concis qui répond à la requête de l'utilisateur en fonction des résumés des pages web ci-dessus. Structurez votre réponse avec :
                1. Une réponse directe à la requête
                2. Les éléments clés
                3. Tout contexte important ou mise en garde

                Limitez le résumé à moins de 300 mots.
                """
            } else {
                prompt = """
                User Query: \(query)

                Web Page Summaries:
                \(selectedContext)

                Please provide a concise summary that answers the user's query based on the above web content. Structure your response with:
                1. A direct answer to the query
                2. Key supporting details
                3. Any important context or caveats

                Keep the summary under 300 words.
                """
            }

            // Configure generation options using the effective (clamped) token limit
            let options = GenerationOptions(
                temperature: temperature,
                maximumResponseTokens: effectiveMaxTokens
            )

            // Generate the summary
            let response = try await session.respond(to: prompt, options: options)
            let txt_response = String(describing: response.content)

            return txt_response
        } catch {
            print("⚠️ Error generating summary with Foundation Models: \(error.localizedDescription)")
            // Fallback to basic summarization
            return await generateConciseSummary(query: query, context: context, results: results, language: language)
        }
    }

    /// Summarize a single page content
    private func summarizePage(content: String, title: String, url: String, query: String, temperature: Double = 0.3, language: ModelLanguage = .french, maxResponseTokens: Int = 150, maxContentChars: Int = 2000) async -> String {
        do {
            // Create a fresh session for every page so that successive page calls within
            // one search do not accumulate history and overflow the context window.
            let pageInstructions: String
            if language == .french {
                pageInstructions = "Vous êtes un assistant qui résume brièvement le contenu de pages web en 2-3 phrases."
            } else {
                pageInstructions = "You are an assistant that briefly summarizes web page content in 2-3 sentences."
            }
            let session = LanguageModelSession(instructions: pageInstructions)

            // Prepare a prompt to summarize this specific page
            let pageSummaryPrompt: String
            
            if language == .french {
                pageSummaryPrompt = """
                Résumez brièvement le contenu suivant en 2-3 phrases, en mettant l'accent sur les informations pertinentes pour la requête : "\(query)"

                Titre: \(title)
                Contenu: \(content.prefix(maxContentChars))

                Veuillez fournir uniquement le résumé, sans header ou introduction.
                """
            } else {
                pageSummaryPrompt = """
                Briefly summarize the following content in 2-3 sentences, focusing on information relevant to the query: "\(query)"

                Title: \(title)
                Content: \(content.prefix(maxContentChars))

                Please provide only the summary, without header or introduction.
                """
            }

            let options = GenerationOptions(
                temperature: temperature,
                maximumResponseTokens: maxResponseTokens
            )

            let response = try await session.respond(to: pageSummaryPrompt, options: options)
            let pageSummary = String(describing: response.content)

            return "Source: \(title)\nURL: \(url)\nSummary: \(pageSummary)"
        } catch {
            print("⚠️ Error summarizing page: \(error.localizedDescription)")
            // Fallback: return original content info
            return "Source: \(title)\nURL: \(url)\nContent: \(content.prefix(500))..."
        }
    }

    /// Generate a concise summary with links
    private func generateConciseSummary(query: String, context: String, results: [SearchResult], language: ModelLanguage = .french) async -> String {
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

        // Add query context in the selected language
        if language == .french {
            summaryParts.append("Basé sur votre recherche pour '\(query)' :")
        } else {
            summaryParts.append("Based on your search for '\(query)':")
        }
        summaryParts.append("")

        // Add key findings
        if !topSentences.isEmpty {
            summaryParts.append(language == .french ? "**Principaux résultats :**" : "**Key Findings:**")
            for (_, sentence) in topSentences.enumerated() {
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
        summaryParts.append(language == .french ? "**Principales sources :**" : "**Top Sources:**")
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

