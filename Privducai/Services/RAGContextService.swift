//
//  RAGContextService.swift
//  Privducai
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
    let contextWindowLimit: Int
    let avgCharsPerToken: Int
    let instructionTokens: Int
    let promptOverheadTokens: Int
    let minContextTokens: Int
    let contextUtilizationFactor: Double
    let minimumFallbackContextCharacters: Int
    let longChunkCharacterThreshold: Int
    let longChunkBonusScore: Double

    static let `default` = RAGSelectionOptions(
        contextWindowLimit: 4096,
        avgCharsPerToken: 3,
        instructionTokens: 120,
        promptOverheadTokens: 120,
        minContextTokens: 300,
        contextUtilizationFactor: 0.8,
        minimumFallbackContextCharacters: 200,
        longChunkCharacterThreshold: 300,
        longChunkBonusScore: 0.2
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
    private static let embeddingDimensions = 64
    private static let embeddingInputCharacterLimit = 1800

    private var embeddingCache: [String: [Double]] = [:]

    /// Selects the highest-ranked chunks that fit the context budget.
    func selectContext(
        chunks: [RAGChunk],
        query: String,
        maxResponseTokens: Int,
        options: RAGSelectionOptions = .default
    ) async -> RAGSelectionResult {
        guard !chunks.isEmpty else {
            return RAGSelectionResult(
                selectedContext: "No additional context provided.",
                rankedChunks: []
            )
        }

        let maxContextChars = calculateMaxContextCharacters(maxResponseTokens: maxResponseTokens, options: options)
        let queryVector = await embeddingVector(for: query)

        var ranked: [RankedRAGChunk] = []
        ranked.reserveCapacity(chunks.count)
        for chunk in chunks {
            let score = await relevanceScore(text: chunk.text, query: query, queryVector: queryVector, options: options)
            ranked.append(RankedRAGChunk(chunk: chunk, relevanceScore: score))
        }

        ranked.sort { lhs, rhs in
            if lhs.relevanceScore == rhs.relevanceScore {
                return lhs.chunk.text.count > rhs.chunk.text.count
            }
            return lhs.relevanceScore > rhs.relevanceScore
        }

        var selected: [String] = []
        var currentChars = 0
        for rankedChunk in ranked {
            let chunkEntry = "Source: \(rankedChunk.chunk.source)\n\(rankedChunk.chunk.text)"
            if currentChars + chunkEntry.count > maxContextChars {
                continue
            }
            selected.append(chunkEntry)
            currentChars += chunkEntry.count
        }

        if selected.isEmpty, let first = ranked.first {
            let fallback = "Source: \(first.chunk.source)\n\(first.chunk.text)"
            return RAGSelectionResult(
                selectedContext: String(fallback.prefix(max(options.minimumFallbackContextCharacters, maxContextChars))),
                rankedChunks: ranked
            )
        }

        return RAGSelectionResult(
            selectedContext: selected.joined(separator: "\n\n---\n\n"),
            rankedChunks: ranked
        )
    }

    private func calculateMaxContextCharacters(maxResponseTokens: Int, options: RAGSelectionOptions) -> Int {
        let effectiveResponseTokens = min(
            maxResponseTokens,
            options.contextWindowLimit - options.instructionTokens - options.promptOverheadTokens - options.minContextTokens
        )
        let reservedTokens = options.instructionTokens + options.promptOverheadTokens + effectiveResponseTokens
        let availableTokens = max(options.contextWindowLimit - reservedTokens, 0)
        return Int(Double(availableTokens * options.avgCharsPerToken) * options.contextUtilizationFactor)
    }

    private func relevanceScore(text: String, query: String, queryVector: [Double]?, options: RAGSelectionOptions) async -> Double {
        if let queryVector,
           let textVector = await embeddingVector(for: text),
           queryVector.count == textVector.count {
            var score = cosineSimilarity(queryVector, textVector)
            if text.count > options.longChunkCharacterThreshold {
                score += options.longChunkBonusScore
            }
            return score
        }

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

    private func embeddingVector(for rawText: String) async -> [Double]? {
        let text = String(rawText.prefix(Self.embeddingInputCharacterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let cached = embeddingCache[text] {
            return cached
        }

        do {
            let instructions = """
            You are a text embedding generator.
            Return ONLY valid JSON representing an array of exactly \(Self.embeddingDimensions) float values.
            The array must be deterministic for semantically equivalent text and suitable for cosine similarity.
            Do not include any markdown, explanation, or extra keys.
            """
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
            Generate an embedding array with exactly \(Self.embeddingDimensions) normalized floats for this text:
            \(text)
            """
            let options = GenerationOptions(temperature: 0, maximumResponseTokens: 400)
            let response = try await session.respond(to: prompt, options: options)
            let raw = String(describing: response.content)
            guard let parsed = parseEmbedding(from: raw) else { return nil }
            embeddingCache[text] = parsed
            return parsed
        } catch {
            return nil
        }
    }

    private func parseEmbedding(from raw: String) -> [Double]? {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"),
              start <= end else {
            return nil
        }
        let jsonSlice = raw[start...end]
        guard let data = String(jsonSlice).data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Double],
              values.count == Self.embeddingDimensions else {
            return nil
        }
        return normalize(values)
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let dot = zip(lhs, rhs).reduce(0.0) { partial, pair in
            partial + (pair.0 * pair.1)
        }
        return max(min(dot, 1.0), -1.0)
    }

    private func normalize(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
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

        let isFrench = language == .french
        let title = isFrench ? "Top 3 extraits pertinents :" : "Top 3 relevant chunks:"
        let urlLabel = isFrench ? "URL" : "URL"
        let pageLabel = isFrench ? "Page PDF" : "PDF Page"

        let lines = chunks.enumerated().flatMap { index, ranked -> [String] in
            var row: [String] = []
            row.append("\(index + 1). Source: \(ranked.chunk.source)")
            if let url = ranked.chunk.url {
                row.append("   \(urlLabel): \(url)")
            }
            if let page = ranked.chunk.pdfPage {
                row.append("   \(pageLabel): \(page)")
            }
            return row
        }

        return "\n\n\(title)\n" + lines.joined(separator: "\n")
    }
}
