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
    private var queryExpanderSession: LanguageModelSession
    private var queryExpanderSessionLanguage: ModelLanguage

    private static let webChunkMaxTokens = 240
    private static let webChunkOverlapTokens = 40
    private static let fastSummaryContextUtilizationFactor = 0.50
    private static let deepSummaryContextUtilizationFactor = 0.65
    private static let fastSummaryScrapingResultCap = 6
    private static let fastSummaryScrapingCharacterCap = 4500

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[AIService] \(message)")
        #endif
    }

    init(initialFirstGuessLanguage: ModelLanguage = .french) {
        self.firstGuessSessionLanguage = initialFirstGuessLanguage
        self.firstGuessSession = LanguageModelSession(
            instructions: Self.buildFirstGuessInstructions(for: initialFirstGuessLanguage)
        )
        self.queryExpanderSessionLanguage = initialFirstGuessLanguage
        self.queryExpanderSession = LanguageModelSession(
            instructions: Self.buildQueryExpanderInstructions(for: initialFirstGuessLanguage)
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

    /// Expands one query into up to `maxDerivedQueries` related web-search queries.
    func expandSearchQueries(
        query: String,
        language: ModelLanguage = .french,
        maxDerivedQueries: Int = 3
    ) async -> [String] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, maxDerivedQueries > 0 else { return [] }

        let fallback = fallbackDerivedQueries(
            for: trimmedQuery,
            language: language,
            maxDerivedQueries: maxDerivedQueries
        )

        do {
            let session = queryExpanderSession(for: language)
            let raw = String(describing: try await session.respond(
                to: queryExpanderPrompt(for: trimmedQuery, language: language, maxDerivedQueries: maxDerivedQueries),
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 140)
            ).content)

            let rawCandidates = raw
                .components(separatedBy: .newlines)
                .map { sanitizeDerivedQueryLine($0) }
                .filter { !$0.isEmpty }

            let parsed = parseDerivedQueries(
                raw,
                originalQuery: trimmedQuery,
                maxDerivedQueries: maxDerivedQueries
            )

            let completed = completeDerivedQueries(
                parsed,
                originalQuery: trimmedQuery,
                fallback: fallback,
                language: language,
                maxDerivedQueries: maxDerivedQueries
            )

            debugLog(
                "query expansion counts: expected=\(maxDerivedQueries), raw=\(rawCandidates.count), keptNonURL=\(parsed.count), completed=\(completed.count)"
            )
            debugLog("query expansion final: \(completed.joined(separator: " | "))")

            return completed
        } catch {
            let completed = completeDerivedQueries(
                [],
                originalQuery: trimmedQuery,
                fallback: fallback,
                language: language,
                maxDerivedQueries: maxDerivedQueries
            )
            debugLog("query expansion fallback-only due to error: \(error.localizedDescription)")
            debugLog("query expansion final: \(completed.joined(separator: " | "))")
            return completed
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

        let effectiveScrapingResults = profile == .fast
            ? min(maxScrapingResults, Self.fastSummaryScrapingResultCap)
            : maxScrapingResults
        let effectiveScrapingChars = profile == .fast
            ? min(maxScrapingChars, Self.fastSummaryScrapingCharacterCap)
            : maxScrapingChars

        // Scrape only URLs without provider-supplied full content.
        let urlsToScrape = results.compactMap { result -> String? in
            guard result.retrievedContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                return nil
            }
            return result.url
        }
        let scrapedContent: [String: String]
        #if DEBUG
        let scrapeStart = Date()
        scrapedContent = await webScraper.scrapeMultiplePages(
            urls: urlsToScrape,
            limit: effectiveScrapingResults,
            maxCharacters: effectiveScrapingChars
        )
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
        scrapedContent = await webScraper.scrapeMultiplePages(
            urls: urlsToScrape,
            limit: effectiveScrapingResults,
            maxCharacters: effectiveScrapingChars
        )
        #endif

        _ = skipPerPageSummary
        var chunks: [RAGChunk] = []
        #if DEBUG
        let contextPrepStart = Date()
        #endif
        for result in results {
            if let retrievedContent = result.retrievedContent?.trimmingCharacters(in: .whitespacesAndNewlines),
               !retrievedContent.isEmpty {
                let chunked = ragChunker.chunk(
                    text: retrievedContent,
                    source: result.title,
                    maxChunkTokens: Self.webChunkMaxTokens,
                    overlapTokens: Self.webChunkOverlapTokens,
                    url: result.url
                )
                chunks.append(contentsOf: chunked)
            } else if let pageContent = scrapedContent[result.url] {
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

    /// Builds instructions for query expansion during deep web search.
    private static func buildQueryExpanderInstructions(for language: ModelLanguage) -> String {
        if language == .french {
            return """
            Retourne des requêtes de recherche web pour la question.
            """
        }

        return """
        Return web search queries for the question.
        """
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

    /// Returns a long-lived query-expander session and rebuilds it when language changes.
    private func queryExpanderSession(for language: ModelLanguage) -> LanguageModelSession {
        if language != queryExpanderSessionLanguage {
            queryExpanderSessionLanguage = language
            queryExpanderSession = LanguageModelSession(
                instructions: Self.buildQueryExpanderInstructions(for: language)
            )
        }

        return queryExpanderSession
    }

    /// Prompt used to produce search-query expansions in the active UI language.
    private func queryExpanderPrompt(for query: String, language: ModelLanguage, maxDerivedQueries: Int) -> String {
        if language == .french {
            return """
            Question: \(query)

            Retourne exactement \(maxDerivedQueries) requêtes de recherche web pour la question, en texte brut, une par ligne, sans numérotation, sans commentaires.
            """
        }

        return """
        Question: \(query)

        Output exactly \(maxDerivedQueries) search queries for the question, plain text, one per line, no numbering, no comments.
        """
    }

    /// Parses one-query-per-line model output and removes duplicates/noise.
    private func parseDerivedQueries(_ raw: String, originalQuery: String, maxDerivedQueries: Int) -> [String] {
        var seen = Set<String>()
        let normalizedOriginal = normalizeQueryKey(originalQuery)
        seen.insert(normalizedOriginal)

        let queries = raw
            .components(separatedBy: .newlines)
            .map { sanitizeDerivedQueryLine($0) }
            .filter { !$0.isEmpty }
            .filter { !isRawURLSearchQuery($0) }
            .filter { isMeaningfullyDifferentFromOriginal($0, originalQuery: originalQuery) }
            .filter { candidate in
                seen.insert(normalizeQueryKey(candidate)).inserted
            }
            .filter { !isNearDuplicate(ofAny: $0, in: [originalQuery]) }

        return Array(queries.prefix(maxDerivedQueries))
    }

    /// Removes bullets/numbering artifacts and trims wrapping quotes.
    private func sanitizeDerivedQueryLine(_ line: String) -> String {
        let withoutPrefix = line.replacingOccurrences(
            of: #"^\s*(?:[-*•]|\d+[.)])\s*"#,
            with: "",
            options: .regularExpression
        )

        return withoutPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes a query for case-insensitive deduplication.
    private func normalizeQueryKey(_ query: String) -> String {
        query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detects lines that are raw links instead of plain search query text.
    private func isRawURLSearchQuery(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.range(
            of: #"^(?i)(?:https?://|www\.)\S+$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if trimmed.contains(" ") {
            return false
        }

        guard let components = URLComponents(string: trimmed) else {
            return false
        }

        let hasSchemeAndHost =
            (components.scheme?.isEmpty == false) &&
            (components.host?.isEmpty == false)

        return hasSchemeAndHost
    }

    /// Tokenizes text for lightweight lexical-similarity checks.
    private func queryTokenSet(_ query: String) -> Set<String> {
        let normalized = normalizeQueryKey(query)
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = normalized
            .components(separatedBy: separators)
            .filter { $0.count >= 3 }

        return Set(tokens)
    }

    /// Returns true when candidate adds enough novel tokens vs original query.
    private func isMeaningfullyDifferentFromOriginal(_ candidate: String, originalQuery: String) -> Bool {
        let candidateTokens = queryTokenSet(candidate)
        let originalTokens = queryTokenSet(originalQuery)
        guard !candidateTokens.isEmpty else { return false }

        let novelTokens = candidateTokens.subtracting(originalTokens)
        return novelTokens.count >= 2
    }

    /// Rejects near-duplicate variants using Jaccard overlap on token sets.
    private func isNearDuplicate(ofAny candidate: String, in existingQueries: [String]) -> Bool {
        let candidateTokens = queryTokenSet(candidate)
        guard !candidateTokens.isEmpty else { return true }

        for existing in existingQueries {
            let existingTokens = queryTokenSet(existing)
            guard !existingTokens.isEmpty else { continue }

            let intersectionCount = candidateTokens.intersection(existingTokens).count
            let unionCount = candidateTokens.union(existingTokens).count
            guard unionCount > 0 else { continue }

            let similarity = Double(intersectionCount) / Double(unionCount)
            if similarity >= 0.75 {
                return true
            }
        }

        return false
    }

    /// Ensures we always return exactly `maxDerivedQueries` non-URL alternatives.
    private func completeDerivedQueries(
        _ parsed: [String],
        originalQuery: String,
        fallback: [String],
        language: ModelLanguage,
        maxDerivedQueries: Int
    ) -> [String] {
        guard maxDerivedQueries > 0 else { return [] }

        var completed: [String] = []
        var seen = Set<String>()
        seen.insert(normalizeQueryKey(originalQuery))

        let intentFallbacks = fallbackDerivedQueries(
            for: originalQuery,
            language: language,
            maxDerivedQueries: max(5, maxDerivedQueries)
        )

        func shouldKeep(_ cleaned: String) -> Bool {
            guard !cleaned.isEmpty else { return false }
            guard !isRawURLSearchQuery(cleaned) else { return false }
            guard isMeaningfullyDifferentFromOriginal(cleaned, originalQuery: originalQuery) else { return false }
            guard !isNearDuplicate(ofAny: cleaned, in: [originalQuery] + completed) else { return false }
            return true
        }

        func appendIfValid(_ candidate: String) {
            let cleaned = sanitizeDerivedQueryLine(candidate)
            guard shouldKeep(cleaned) else { return }
            guard seen.insert(normalizeQueryKey(cleaned)).inserted else { return }
            completed.append(cleaned)
        }

        for candidate in parsed {
            appendIfValid(candidate)
            if completed.count == maxDerivedQueries { return completed }
        }

        for candidate in fallback {
            appendIfValid(candidate)
            if completed.count == maxDerivedQueries { return completed }
        }

        for candidate in intentFallbacks {
            appendIfValid(candidate)
            if completed.count == maxDerivedQueries { return completed }
        }

        var fillerIndex = 1
        while completed.count < maxDerivedQueries {
            if language == .french {
                appendIfValid("\(originalQuery) méthode fiable \(fillerIndex)")
            } else {
                appendIfValid("\(originalQuery) reliable method \(fillerIndex)")
            }
            fillerIndex += 1

            // Last resort to guarantee progress if strict filters reject too much.
            if fillerIndex > 20 && completed.count < maxDerivedQueries {
                let coarse = language == .french
                    ? "\(originalQuery) guide complet \(completed.count + 1)"
                    : "\(originalQuery) complete guide \(completed.count + 1)"
                let cleaned = sanitizeDerivedQueryLine(coarse)
                if seen.insert(normalizeQueryKey(cleaned)).inserted {
                    completed.append(cleaned)
                }
            }
        }

        return completed
    }

    /// Language-aware intent-based fallback expansions.
    private func fallbackDerivedQueries(for query: String, language: ModelLanguage, maxDerivedQueries: Int) -> [String] {
        let isTravelDistance = looksLikeTravelDistanceQuery(query)

        let candidates: [String]
        if language == .french {
            if isTravelDistance {
                candidates = [
                    "\(query) distance totale km",
                    "\(query) durée trajet voiture train",
                    "\(query) meilleur itinéraire avec péage",
                    "\(query) carte et étapes détaillées",
                    "\(query) données officielles de distance"
                ]
            } else {
                candidates = [
                    "\(query) définition et points clés",
                    "\(query) comparaison des alternatives",
                    "\(query) données récentes source officielle",
                    "\(query) guide pratique étape par étape",
                    "\(query) erreurs fréquentes et vérification"
                ]
            }
        } else {
            if isTravelDistance {
                candidates = [
                    "\(query) total distance in km",
                    "\(query) travel time by car and train",
                    "\(query) best route with toll options",
                    "\(query) map with route steps",
                    "\(query) official distance data sources"
                ]
            } else {
                candidates = [
                    "\(query) definition and key points",
                    "\(query) alternatives comparison",
                    "\(query) latest data official source",
                    "\(query) step by step practical guide",
                    "\(query) common mistakes and validation"
                ]
            }
        }

        return Array(candidates.prefix(maxDerivedQueries))
    }

    /// Heuristic detection for route/distance intents to improve fallback relevance.
    private func looksLikeTravelDistanceQuery(_ query: String) -> Bool {
        let q = normalizeQueryKey(query)
        let travelKeywords = [
            "distance", "trajet", "itineraire", "itinéraire", "route", "km", "kilometre", "kilomètre", "driving", "travel"
        ]
        return travelKeywords.contains { q.contains($0) }
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
