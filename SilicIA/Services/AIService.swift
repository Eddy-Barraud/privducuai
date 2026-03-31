//
//  AIService.swift
//  SilicIA
//
//  Created by Claude on 23/03/2026.
//

import Foundation
import Combine
import NaturalLanguage
import FoundationModels

@MainActor
/// Generates search summaries using Foundation Models with deterministic fallbacks.
class AIService: ObservableObject {
    enum GenerationProfile: String {
        case fast
        case deep
    }

    @Published var isSummarizing = false
    @Published var summary: String = ""
    @Published var citations: String = ""

    #if DEBUG
    struct TimingMetric: Identifiable {
        let id = UUID()
        let name: String
        let seconds: Double
    }

    @Published var debugTimings: [TimingMetric] = []
    @Published var debugNotes: [String] = []
    #endif

    private let webScraper = WebScrapingService()
    private let ragChunker = RAGChunker()
    private let ragContextService = RAGContextService()
    private var firstGuessSession: LanguageModelSession
    private var firstGuessSessionLanguage: ModelLanguage

    private static let webChunkMaxTokens = 240
    private static let webChunkOverlapTokens = 40
    private static let fastSummaryContextUtilizationFactor = 0.50
    private static let deepSummaryContextUtilizationFactor = 0.65

    init(initialFirstGuessLanguage: ModelLanguage = .french) {
        self.firstGuessSessionLanguage = initialFirstGuessLanguage
        self.firstGuessSession = LanguageModelSession(
            instructions: Self.buildFirstGuessInstructions(for: initialFirstGuessLanguage)
        )
    }

    /// Generates a tiny no-context intuition to provide immediate feedback.
    func generateFirstGuess(
        query: String,
        language: ModelLanguage = .french,
        temperature: Double = 0.3,
        maxTokens: Int = 150
    ) async -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return "" }

        do {
            let session = firstGuessSession(for: language)
            let prompt = PromptLoader.loadPrompt(
                mode: "quick",
                feature: "search",
                language: language,
                replacements: ["query": trimmedQuery]
            ) ?? fallbackFirstGuessPrompt(for: trimmedQuery, language: language)

            let options = GenerationOptions(
                temperature: temperature,
                maximumResponseTokens: maxTokens
            )

            let response = try await session.respond(to: prompt, options: options)
            let content = String(describing: response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if content.isEmpty {
                return fallbackFirstGuess(for: trimmedQuery, language: language)
            }

            let sanitized = sanitizeLaTeXDocumentWrappers(content)
            return sanitized.isEmpty ? fallbackFirstGuess(for: trimmedQuery, language: language) : sanitized
        } catch {
            return fallbackFirstGuess(for: trimmedQuery, language: language)
        }
    }

    /// Summarize search results using Foundation Models or fallback to NLP.
    ///
    /// The Search Assist flow uses the same chunking/relevance selection pipeline as chat.
    /// - Parameter skipPerPageSummary: Kept for API compatibility with existing call sites.
    func summarize(query: String, results: [SearchResult], maxScrapingResults: Int = 10, maxScrapingChars: Int = 5000, temperature: Double = 0.3, maxTokens: Int = 1000, language: ModelLanguage = .french, profile: GenerationProfile = .fast, skipPerPageSummary: Bool = false) async -> (summary: String, citations: String) {
        isSummarizing = true
        defer { isSummarizing = false }

        #if DEBUG
        debugTimings = []
        debugNotes = []
        let summarizeStart = Date()
        #endif

        // Scrape content from top pages
        let urls = results.map { $0.url }
        let scrapedContent: [String: String]
        #if DEBUG
        let scrapeStart = Date()
        scrapedContent = await webScraper.scrapeMultiplePages(urls: urls, limit: maxScrapingResults, maxCharacters: maxScrapingChars)
        debugTimings.append(TimingMetric(
            name: "WebScrapingService.scrapeMultiplePages",
            seconds: Date().timeIntervalSince(scrapeStart)
        ))
        if let stats = webScraper.lastDebugStats {
            if stats.candidateURLCount <= stats.requestedLimit {
                debugNotes.append(
                    "overfetch unavailable: candidates (\(stats.candidateURLCount)) <= requested (\(stats.requestedLimit))"
                )
            }
            debugNotes.append(
                "scrape stats: requested=\(stats.requestedLimit), candidates=\(stats.candidateURLCount), launched=\(stats.launchedTasks), completed=\(stats.completedTasks), succeeded=\(stats.succeededPages), canceled=\(stats.canceledTasks), pool=\(stats.poolSize), overfetch=+\(stats.overfetchCount), earlyCancel=\(stats.didEarlyCancel)"
            )
            debugNotes.append(String(format: "scrape elapsed (service): %.3f s", stats.elapsedSeconds))
        }
        #else
        scrapedContent = await webScraper.scrapeMultiplePages(urls: urls, limit: maxScrapingResults, maxCharacters: maxScrapingChars)
        #endif

        _ = skipPerPageSummary
        var chunks: [RAGChunk] = []
        #if DEBUG
        let contextPrepStart = Date()
        #endif
        for result in results {
            if let pageContent = scrapedContent[result.url] {
                let chunked = ragChunker.chunk(
                    text: pageContent,
                    source: result.title,
                    maxChunkTokens: Self.webChunkMaxTokens,
                    overlapTokens: Self.webChunkOverlapTokens,
                    url: result.url
                )
                chunks.append(contentsOf: chunked)
            } else {
                let chunked = ragChunker.chunk(
                    text: result.snippet,
                    source: result.title,
                    maxChunkTokens: Self.webChunkMaxTokens,
                    overlapTokens: Self.webChunkOverlapTokens,
                    url: result.url
                )
                chunks.append(contentsOf: chunked)
            }
        }

        let effectiveMaxTokens = TokenBudgeting.clampedOutputTokens(
            requestedMaxTokens: maxTokens,
            instructionTokens: TokenBudgeting.instructionTokens,
            promptOverheadTokens: TokenBudgeting.promptOverheadTokens,
            minContextTokens: TokenBudgeting.minContextTokens
        )
        let contextUtilizationFactor = profile == .deep
            ? Self.deepSummaryContextUtilizationFactor
            : Self.fastSummaryContextUtilizationFactor
        let selected = await ragContextService.selectContext(
            chunks: chunks,
            query: query,
            maxOutputTokens: effectiveMaxTokens,
            contextUtilizationFactor: contextUtilizationFactor
        )

        #if DEBUG
        debugTimings.append(TimingMetric(
            name: "RAG context prep (chunk + select)",
            seconds: Date().timeIntervalSince(contextPrepStart)
        ))
        #endif

        // Try Foundation Models first, fallback to NLP if it fails
        #if DEBUG
        let generationStart = Date()
        #endif
        let summary = await generateSummaryWithFoundationModels(
            query: query,
            context: selected.selectedContext,
            results: results,
            temperature: temperature,
            maxTokens: maxTokens,
            language: language,
            profile: profile
        )

        #if DEBUG
        debugTimings.append(TimingMetric(
            name: "generateSummaryWithFoundationModels",
            seconds: Date().timeIntervalSince(generationStart)
        ))
        #endif
        let citations = RAGCitationFormatter.citationBlock(from: selected.topChunks, language: language)

        #if DEBUG
        debugTimings.append(TimingMetric(
            name: "AIService.summarize (total)",
            seconds: Date().timeIntervalSince(summarizeStart)
        ))
        #endif

        self.summary = summary
        self.citations = citations
        return (summary: summary, citations: citations)
    }

    /// Builds compact instructions for the selected response language.
    private func buildInstructions(for language: ModelLanguage) -> String {
        PromptLoader.loadPrompt(mode: "normal", feature: "search", variant: "instructions", language: language)
            ?? fallbackSummaryInstructions(for: language)
    }

    /// Builds instructions for an ultra-short first-guess response.
    private static func buildFirstGuessInstructions(for language: ModelLanguage) -> String {
        PromptLoader.loadPrompt(mode: "quick", feature: "search", variant: "instructions", language: language)
            ?? fallbackFirstGuessInstructions(for: language)
    }

    /// Returns a long-lived first-guess session and rebuilds it when language changes.
    private func firstGuessSession(for language: ModelLanguage) -> LanguageModelSession {
        if language != firstGuessSessionLanguage {
            firstGuessSessionLanguage = language
            firstGuessSession = LanguageModelSession(
                instructions: Self.buildFirstGuessInstructions(for: language)
            )
        }

        return firstGuessSession
    }

    /// Fallback guess used when on-device generation is unavailable.
    private func fallbackFirstGuess(for query: String, language: ModelLanguage) -> String {
        if language == .french {
            return "Intuition rapide : la réponse dépend du contexte exact. Je lance une vérification web pour confirmer les points clés sur \"\(query)\"."
        }

        return "Quick intuition: the answer depends on the exact context. I am checking web sources to confirm the key points about \"\(query)\"."
    }

    /// Removes full LaTeX document wrappers that the renderer does not expect.
    private func sanitizeLaTeXDocumentWrappers(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let beginRange = cleaned.range(of: "\\begin{document}"),
           let endRange = cleaned.range(of: "\\end{document}"),
           beginRange.upperBound <= endRange.lowerBound {
            cleaned = String(cleaned[beginRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s*\\documentclass(?:\[[^\]]*\])?\{[^}]*\}\s*$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s*\\usepackage(?:\[[^\]]*\])?\{[^}]*\}\s*$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\\begin{document}", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\\end{document}", with: "")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generates the final summary through Foundation Models with context budgeting.
    private func generateSummaryWithFoundationModels(query: String, context: String, results: [SearchResult], temperature: Double = 0.3, maxTokens: Int = 1000, language: ModelLanguage = .french, profile: GenerationProfile = .fast) async -> String {
        do {
            // Always create a fresh session so that context from previous searches
            // does not accumulate and overflow the context window.
            let instructions = buildInstructions(for: language)
            let session = LanguageModelSession(instructions: instructions)

            let isDeepProfile = profile == .deep

            // Token budget for the final summary.
            let effectiveMaxTokens = TokenBudgeting.clampedOutputTokens(
                requestedMaxTokens: maxTokens,
                instructionTokens: TokenBudgeting.instructionTokens,
                promptOverheadTokens: TokenBudgeting.promptOverheadTokens,
                minContextTokens: TokenBudgeting.minContextTokens
            )
            let maxContextChars = TokenBudgeting.maxContextCharacters(
                maxOutputTokens: effectiveMaxTokens,
                contextUtilizationFactor: isDeepProfile ? Self.deepSummaryContextUtilizationFactor : Self.fastSummaryContextUtilizationFactor
            )
            
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

            let prompt = PromptLoader.loadPrompt(
                mode: "normal",
                feature: "search",
                language: language,
                replacements: [
                    "query": query,
                    "context": selectedContext,
                    "maxOutputTokens": "\(effectiveMaxTokens)",
                    "keyPointsRange": isDeepProfile ? "4 to 6" : "1 to 3",
                    "keyPointsRangeFr": isDeepProfile ? "4 à 6" : "1 à 3"
                ]
            ) ?? fallbackSummaryPrompt(
                query: query,
                context: selectedContext,
                language: language,
                isDeepProfile: isDeepProfile,
                maxOutputTokens: effectiveMaxTokens
            )

            #if DEBUG
            debugNotes.append(
                "generation profile=\(profile.rawValue), budget: reqTokens=\(maxTokens), effTokens=\(effectiveMaxTokens), contextCharsIn=\(context.count), contextCharsUsed=\(selectedContext.count), promptChars=\(prompt.count)"
            )
            #endif

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

    /// Builds an extractive fallback summary.
    private func generateConciseSummary(query: String, context: String, results: [SearchResult], language: ModelLanguage = .french) async -> String {
        // For M3 MacBooks without full Apple Intelligence, we'll create an efficient
        // extractive summary that highlights key information

        let isFrench = language == .french

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
        if isFrench {
            summaryParts.append("Basé sur votre recherche pour '\(query)' :")
        } else {
            summaryParts.append("Based on your search for '\(query)':")
        }
        summaryParts.append("")

        // Add key findings
        if !topSentences.isEmpty {
            summaryParts.append(isFrench ? "**Principaux résultats :**" : "**Key Findings:**")
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

        return summaryParts.joined(separator: "\n")
    }

    private static func fallbackFirstGuessInstructions(for language: ModelLanguage) -> String {
        if language == .french {
            return """
            Vous êtes un assistant de chat utile. Répondez clairement et précisément.
            Répondez en français.
            """
        }

        return """
        You are a helpful chat assistant. Answer the user clearly and accurately.
        Respond in English.
        """
    }

    private func fallbackSummaryInstructions(for language: ModelLanguage) -> String {
        if language == .french {
            return """
            Tu produis un résumé web précis et concis.
            Réponds en français.
            Donne une réponse directe, puis 1 à 3 points clés.
            Si une information est incertaine, indique-le clairement.
            """
        }

        return """
        You produce concise, accurate web summaries.
        Respond in English.
        Give a direct answer, then 1 to 3 key points.
        If information is uncertain, state it explicitly.
        """
    }

    private func fallbackFirstGuessPrompt(for query: String, language: ModelLanguage) -> String {
        if language == .french {
            return """
            Question: \(query)

            Réponds de manière courte, précise et factuelle.
            Réponds en français.
            Réponds en une phrase maximum.
            Si pertinent, inclus une expression mathématique courte.
            Format de sortie attendu : LaTeX pour les expressions mathématiques, avec $...$ en inline.
            """
        }

        return """
        Question: \(query)

        Answer in a short, precise and factual manner.
        Answer in English.
        Answer in one sentence maximum.
        If relevant, include a short mathematical expression.
        Required output format: LaTeX for mathematical expressions, using $...$ inline.
        """
    }

    private func fallbackSummaryPrompt(
        query: String,
        context: String,
        language: ModelLanguage,
        isDeepProfile: Bool,
        maxOutputTokens: Int
    ) -> String {
        if language == .french {
            return """
            Question : \(query)

            Contexte web :
            \(context)

            Réponds avec :
            1. Une réponse directe.
            2. \(isDeepProfile ? "4 à 6" : "1 à 3") points clés.
            Limite : \(maxOutputTokens) tokens maximum.
            Format de sortie attendu : LaTeX pour les expressions mathématiques.
            Quand c'est pertinent, inclus des formules mathématiques avec du LaTeX simple.
            Format math attendu: inline avec $...$ et blocs avec \\[...\\].
            N'utilise jamais d'environnements \\begin{.
            """
        }

        return """
        Question: \(query)

        Web context:
        \(context)

        Respond with:
        1. A direct answer.
        2. \(isDeepProfile ? "4 to 6" : "1 to 3") key points.
        Limit: \(maxOutputTokens) tokens maximum.
        Required output format: LaTeX for mathematical expressions.
        When relevant, include mathematical formulas in simple LaTeX.
        Required math format: use $...$ inline and \\[...\\].
        Never use environments with \\begin{.
        """
    }

    /// Calculates lexical relevance of one sentence against the query.
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

}
