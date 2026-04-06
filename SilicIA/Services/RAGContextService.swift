//
//  RAGContextService.swift
//  SilicIA
//
//  Created by Eddy Barraud on 27/03/2026.
//

import Foundation
import FoundationModels

/// Represents a retrieval chunk and its source metadata.
struct RAGChunk: Identifiable {
    let id = UUID()
    let source: String
    let text: String
    let url: String?
    let pdfPage: Int?
}

/// Splits long context text into overlapping retrieval chunks.
struct RAGChunker {
    private static let avgCharsPerToken = 3
    private static let whitespacePattern = "\\s+"
    private static let minimumChunkCharacters = 200

    /// Chunks text with overlap while preserving non-empty slices.
    func chunk(
        text: String,
        source: String,
        maxChunkTokens: Int,
        overlapTokens: Int,
        url: String? = nil,
        pdfPage: Int? = nil
    ) -> [RAGChunk] {
        let cleanText = text
            .replacingOccurrences(of: Self.whitespacePattern, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanText.isEmpty else { return [] }

        let maxChunkChars = max(Self.minimumChunkCharacters, maxChunkTokens * Self.avgCharsPerToken)
        let overlapChars = min(maxChunkChars / 2, max(0, overlapTokens * Self.avgCharsPerToken))
        let stride = max(1, maxChunkChars - overlapChars)

        var chunks: [RAGChunk] = []
        var start = cleanText.startIndex

        while start < cleanText.endIndex {
            let end = cleanText.index(start, offsetBy: maxChunkChars, limitedBy: cleanText.endIndex) ?? cleanText.endIndex
            let piece = String(cleanText[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(RAGChunk(source: source, text: piece, url: url, pdfPage: pdfPage))
            }

            if end == cleanText.endIndex { break }
            start = cleanText.index(start, offsetBy: stride, limitedBy: cleanText.endIndex) ?? cleanText.endIndex
        }

        return chunks
    }
}

/// Parameters used to keep retrieved context within the model context window.
struct RAGSelectionOptions {
    let avgCharsPerToken: Int
    let instructionTokens: Int
    let promptOverheadTokens: Int
    let minContextTokens: Int
    let contextUtilizationFactor: Double
    let minimumFallbackContextCharacters: Int
    let longChunkCharacterThreshold: Int
    let longChunkBonusScore: Double
    let minimumModelScoringCandidates: Int
    let modelScoringTopKLimit: Int
    let modelScoringContextMultiplier: Int
    let maxModelScoringCalls: Int
    let maxConsecutiveModelFailures: Int

    nonisolated static let `default` = RAGSelectionOptions(
        avgCharsPerToken: TokenBudgeting.avgCharsPerToken,
        instructionTokens: TokenBudgeting.instructionTokens,
        promptOverheadTokens: TokenBudgeting.promptOverheadTokens,
        minContextTokens: TokenBudgeting.minContextTokens,
        contextUtilizationFactor: 0.8,
        minimumFallbackContextCharacters: 200,
        longChunkCharacterThreshold: 300,
        longChunkBonusScore: 0.2,
        minimumModelScoringCandidates: 10,
        modelScoringTopKLimit: 24,
        modelScoringContextMultiplier: 2,
        maxModelScoringCalls: 10,
        maxConsecutiveModelFailures: 4
    )
}

/// One ranked chunk returned by relevance scoring.
struct RankedRAGChunk {
    let chunk: RAGChunk
    let relevanceScore: Double
}

/// Output of the shared context selection pipeline.
struct RAGSelectionResult {
    let selectedContext: String
    let rankedChunks: [RankedRAGChunk]

    var topChunks: [RankedRAGChunk] {
        Array(rankedChunks.prefix(3))
    }
}

/// Shared context selection/relevance service for chat and search.
actor RAGContextService {
    private static let scoreCacheLimit = 256
    private var scoreCache: [String: Double] = [:]
    private var scoreCacheOrder: [String] = []

    /// Selects the highest-ranked chunks that fit the context budget.
    /// - Parameter maxOutputTokens: Requested response-token budget used to compute remaining context space.
    /// - Parameter contextUtilizationFactor: Optional context budget multiplier.
    ///   When nil, `options.contextUtilizationFactor` is used.
    func selectContext(
        chunks: [RAGChunk],
        query: String,
        language: ModelLanguage,
        maxOutputTokens: Int,
        contextUtilizationFactor: Double? = nil,
        options: RAGSelectionOptions = .default
    ) async -> RAGSelectionResult {
        #if DEBUG
        let selectionStart = Date()
        #endif

        guard !chunks.isEmpty else {
            return RAGSelectionResult(
                selectedContext: "No additional context provided.",
                rankedChunks: []
            )
        }

        let utilization = contextUtilizationFactor ?? options.contextUtilizationFactor
        let maxContextChars = await calculateMaxContextCharacters(
            maxOutputTokens: maxOutputTokens,
            contextUtilizationFactor: utilization,
            options: options
        )

        var ranked = await rankChunksWithModel(
            chunks: chunks,
            query: query,
            language: language,
            maxContextChars: maxContextChars,
            options: options
        )

        ranked.sort { lhs, rhs in
            if lhs.relevanceScore == rhs.relevanceScore {
                return lhs.chunk.text.count > rhs.chunk.text.count
            }
            return lhs.relevanceScore > rhs.relevanceScore
        }

        var selected: [String] = []
        var currentChars = 0
        let separator = "\n\n---\n\n"
        for rankedChunk in ranked {
            let header = "Source: \(rankedChunk.chunk.source)\n"
            let separatorChars = selected.isEmpty ? 0 : separator.count
            let remainingCharacters = maxContextChars - currentChars - separatorChars
            guard remainingCharacters > header.count else {
                break
            }

            if header.count + rankedChunk.chunk.text.count <= remainingCharacters {
                let chunkEntry = header + rankedChunk.chunk.text
                selected.append(chunkEntry)
                currentChars += separatorChars + chunkEntry.count
                continue
            }

            let availableTextCharacters = max(remainingCharacters - header.count, 0)
            let trimmedText = String(rankedChunk.chunk.text.prefix(availableTextCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                let chunkEntry = header + trimmedText
                selected.append(chunkEntry)
                currentChars += separatorChars + chunkEntry.count
            }
            break
        }

        if selected.isEmpty, let first = ranked.first {
            let fallback = "Source: \(first.chunk.source)\n\(first.chunk.text)"
            #if DEBUG
            let elapsed = Date().timeIntervalSince(selectionStart)
            debugTiming("selectContext chunks=\(chunks.count) ranked=\(ranked.count) selected=1 elapsed=\(formatSeconds(elapsed))s (fallback)")
            #endif
            return RAGSelectionResult(
                selectedContext: String(fallback.prefix(max(options.minimumFallbackContextCharacters, maxContextChars))),
                rankedChunks: ranked
            )
        }

        #if DEBUG
        let elapsed = Date().timeIntervalSince(selectionStart)
        debugTiming("selectContext chunks=\(chunks.count) ranked=\(ranked.count) selected=\(selected.count) elapsed=\(formatSeconds(elapsed))s")
        #endif

        return RAGSelectionResult(
            selectedContext: selected.joined(separator: separator),
            rankedChunks: ranked
        )
    }

    private func calculateMaxContextCharacters(
        maxOutputTokens: Int,
        contextUtilizationFactor: Double,
        options: RAGSelectionOptions
    ) async -> Int {
        await MainActor.run {
            TokenBudgeting.maxContextCharacters(
                maxOutputTokens: maxOutputTokens,
                contextUtilizationFactor: contextUtilizationFactor,
                instructionTokens: options.instructionTokens,
                promptOverheadTokens: options.promptOverheadTokens,
                minContextTokens: options.minContextTokens,
                avgCharsPerToken: options.avgCharsPerToken
            )
        }
    }

    private func relevanceScore(text: String, query: String, options: RAGSelectionOptions) -> Double {
        let queryWords = Set(tokenize(query).filter { $0.count > 2 })
        guard !queryWords.isEmpty else { return 0 }

        let textWords = Set(tokenize(text))
        var score = 0.0
        for word in queryWords where textWords.contains(word) {
            score += 1.0
        }
        if text.count > options.longChunkCharacterThreshold {
            score += options.longChunkBonusScore
        }
        return score
    }

    private func rankChunksWithModel(
        chunks: [RAGChunk],
        query: String,
        language: ModelLanguage,
        maxContextChars: Int,
        options: RAGSelectionOptions
    ) async -> [RankedRAGChunk] {
        var modelCalls = 0
        #if DEBUG
        let rankingStart = Date()
        var cacheHits = 0
        var cacheMisses = 0
        var skippedByPreselection = 0
        var skippedByCircuitBreaker = 0
        var skippedByModelCallCap = 0
        var modelFailures = 0
        var parseFailures = 0
        var circuitBreakerTriggered = false
        var modelCallCapTriggered = false
        #endif

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return chunks.map { chunk in
                RankedRAGChunk(chunk: chunk, relevanceScore: relevanceScore(text: chunk.text, query: query, options: options))
            }
        }

        var lexicalRanked: [RankedRAGChunk] = []
        lexicalRanked.reserveCapacity(chunks.count)
        for chunk in chunks {
            let lexicalScore = relevanceScore(text: chunk.text, query: trimmedQuery, options: options)
            lexicalRanked.append(RankedRAGChunk(chunk: chunk, relevanceScore: lexicalScore))
        }
        lexicalRanked.sort { lhs, rhs in
            if lhs.relevanceScore == rhs.relevanceScore {
                return lhs.chunk.text.count > rhs.chunk.text.count
            }
            return lhs.relevanceScore > rhs.relevanceScore
        }

        let averageChunkCharacters = max(
            1,
            chunks.reduce(0) { partialResult, chunk in
                partialResult + chunk.text.count
            } / max(chunks.count, 1)
        )
        let estimatedChunksNeeded = max(1, Int(ceil(Double(maxContextChars) / Double(max(averageChunkCharacters, 1)))))
        let preselectionCount = min(
            chunks.count,
            max(
                options.minimumModelScoringCandidates,
                min(options.modelScoringTopKLimit, estimatedChunksNeeded * options.modelScoringContextMultiplier)
            )
        )

        var scoresByChunkID: [UUID: Double] = [:]
        scoresByChunkID.reserveCapacity(chunks.count)
        for ranked in lexicalRanked {
            scoresByChunkID[ranked.chunk.id] = ranked.relevanceScore
        }

        if preselectionCount < lexicalRanked.count {
            #if DEBUG
            skippedByPreselection = lexicalRanked.count - preselectionCount
            #endif
        }

        let instructions = rankingInstructions(for: language)
        var session: LanguageModelSession?
        let generationOptions = GenerationOptions(temperature: 0, maximumResponseTokens: 12)
        var consecutiveModelFailures = 0
        var disableModelScoring = false
        var modelScoringDisabledByCallCap = false

        for lexical in lexicalRanked.prefix(preselectionCount) {
            let chunk = lexical.chunk
            let cacheKey = scoreCacheKey(for: chunk, query: trimmedQuery, language: language)
            if let cachedScore = scoreCache[cacheKey] {
                scoresByChunkID[chunk.id] = cachedScore
                #if DEBUG
                cacheHits += 1
                #endif
                continue
            }

            #if DEBUG
            cacheMisses += 1
            #endif

            if disableModelScoring {
                #if DEBUG
                if modelScoringDisabledByCallCap {
                    skippedByModelCallCap += 1
                } else {
                    skippedByCircuitBreaker += 1
                }
                #endif
                continue
            }

            if modelCalls >= options.maxModelScoringCalls {
                disableModelScoring = true
                modelScoringDisabledByCallCap = true
                #if DEBUG
                skippedByModelCallCap += 1
                modelCallCapTriggered = true
                #endif
                continue
            }

            let prompt = rankingPrompt(for: chunk, query: trimmedQuery, language: language)
            do {
                if session == nil {
                    session = LanguageModelSession(instructions: instructions)
                }
                guard let activeSession = session else {
                    let fallback = relevanceScore(text: chunk.text, query: trimmedQuery, options: options)
                    scoresByChunkID[chunk.id] = fallback
                    cacheScore(fallback, for: cacheKey)
                    consecutiveModelFailures += 1
                    if consecutiveModelFailures >= options.maxConsecutiveModelFailures {
                        disableModelScoring = true
                    }
                    #if DEBUG
                    modelFailures += 1
                    if disableModelScoring {
                        circuitBreakerTriggered = true
                    }
                    #endif
                    continue
                }
                modelCalls += 1
                let response = try await activeSession.respond(to: prompt, options: generationOptions)
                let raw = String(describing: response.content)
                if let modelScore = parseModelScore(from: raw) {
                    scoresByChunkID[chunk.id] = modelScore
                    cacheScore(modelScore, for: cacheKey)
                    consecutiveModelFailures = 0
                } else {
                    let fallback = relevanceScore(text: chunk.text, query: trimmedQuery, options: options)
                    scoresByChunkID[chunk.id] = fallback
                    cacheScore(fallback, for: cacheKey)
                    consecutiveModelFailures += 1
                    if consecutiveModelFailures >= options.maxConsecutiveModelFailures {
                        disableModelScoring = true
                    }
                    #if DEBUG
                    parseFailures += 1
                    if disableModelScoring {
                        circuitBreakerTriggered = true
                    }
                    #endif
                }
            } catch {
                let fallback = relevanceScore(text: chunk.text, query: trimmedQuery, options: options)
                scoresByChunkID[chunk.id] = fallback
                cacheScore(fallback, for: cacheKey)
                consecutiveModelFailures += 1
                if consecutiveModelFailures >= options.maxConsecutiveModelFailures {
                    disableModelScoring = true
                }
                #if DEBUG
                modelFailures += 1
                if disableModelScoring {
                    circuitBreakerTriggered = true
                }
                #endif
            }
        }

        var ranked: [RankedRAGChunk] = []
        ranked.reserveCapacity(lexicalRanked.count)
        for lexical in lexicalRanked {
            let finalScore = scoresByChunkID[lexical.chunk.id] ?? lexical.relevanceScore
            ranked.append(RankedRAGChunk(chunk: lexical.chunk, relevanceScore: finalScore))
        }
        ranked.sort { lhs, rhs in
            if lhs.relevanceScore == rhs.relevanceScore {
                return lhs.chunk.text.count > rhs.chunk.text.count
            }
            return lhs.relevanceScore > rhs.relevanceScore
        }

        #if DEBUG
        let elapsed = Date().timeIntervalSince(rankingStart)
        let avgMillis = chunks.isEmpty ? 0 : (elapsed * 1000.0 / Double(chunks.count))
        debugTiming(
            "rankChunks chunks=\(chunks.count) preselected=\(preselectionCount) hits=\(cacheHits) misses=\(cacheMisses) skippedPreselection=\(skippedByPreselection) skippedCircuit=\(skippedByCircuitBreaker) skippedCallCap=\(skippedByModelCallCap) modelCalls=\(modelCalls) modelFailures=\(modelFailures) parseFailures=\(parseFailures) circuitBreaker=\(circuitBreakerTriggered) callCap=\(modelCallCapTriggered) elapsed=\(formatSeconds(elapsed))s avg=\(String(format: "%.1f", avgMillis))ms/chunk"
        )
        #endif

        return ranked
    }

    private func scoreCacheKey(for chunk: RAGChunk, query: String, language: ModelLanguage) -> String {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chunkDescriptor = [
            chunk.source,
            chunk.url ?? "",
            chunk.pdfPage.map(String.init) ?? "",
            chunk.text
        ].joined(separator: "|")

        return "\(language.rawValue)|q:\(stableHash(normalizedQuery))|c:\(stableHash(chunkDescriptor))"
    }

    private func cacheScore(_ score: Double, for key: String) {
        if scoreCache[key] == nil {
            scoreCacheOrder.append(key)
        }
        scoreCache[key] = score

        while scoreCacheOrder.count > Self.scoreCacheLimit {
            let expiredKey = scoreCacheOrder.removeFirst()
            scoreCache.removeValue(forKey: expiredKey)
        }
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    #if DEBUG
    private func debugTiming(_ message: String) {
        print("[RAGContextService][Timing] \(message)")
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
    #endif

    private func rankingInstructions(for language: ModelLanguage) -> String {
        if language == .french {
            return """
            Vous êtes un évaluateur de pertinence pour un système RAG.
            Retournez uniquement un nombre décimal entre 1 et 10, où 10 signifie une correspondance parfaite avec la requête utilisateur.
            N'ajoutez aucun texte, aucune explication, aucune unité.
            """
        }

        return """
        You are a relevance rater for a RAG system.
        Return only one decimal number between 1 and 10, where 10 means a perfect match with the user query.
        Do not add any text, explanation, or units.
        """
    }

    private func rankingPrompt(for chunk: RAGChunk, query: String, language: ModelLanguage) -> String {
        if language == .french {
            return """
            Sur une échelle de 1 à 10 (10 = totalement pertinent), comment noteriez-vous ce texte pour répondre à la requête utilisateur ?

            Requête utilisateur:
            \(query)

            Source:
            \(chunk.source)

            Texte:
            \(chunk.text)

            Retournez uniquement le score numérique.
            """
        }

        return """
        On a scale of 1 to 10 (10 = fully relevant), how would you rate this text for answering the user query?

        User query:
        \(query)

        Source:
        \(chunk.source)

        Text:
        \(chunk.text)

        Return only the numeric score.
        """
    }

    private func parseModelScore(from raw: String) -> Double? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        if let direct = Double(normalized) {
            return min(max(direct, 1), 10)
        }

        let pattern = #"(?:10(?:\.0+)?)|(?:[1-9](?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: range),
              let matchRange = Range(match.range, in: normalized),
              let parsed = Double(String(normalized[matchRange])) else {
            return nil
        }

        return min(max(parsed, 1), 10)
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// Formats source evidence shown under generated answers.
enum RAGCitationFormatter {
    static func citationBlock(from chunks: [RankedRAGChunk], language: ModelLanguage? = nil) -> String {
        guard !chunks.isEmpty else { return "" }

        let pageLabel = language == .french ? "Page PDF" : "PDF Page"

        let lines = chunks.enumerated().map { index, ranked -> String in
            var itemLines: [String] = []

            if let url = ranked.chunk.url {
                itemLines.append("\(index + 1). [\(url)](\(url))")
            } else {
                itemLines.append("\(index + 1). \(ranked.chunk.source)")
            }

            if let page = ranked.chunk.pdfPage {
                itemLines.append("   \(pageLabel): \(page)")
            }

            return itemLines.joined(separator: "\n")
        }

        return lines.joined(separator: "\n\n")
    }
}
