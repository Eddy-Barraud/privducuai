//
//  RAGContextService.swift
//  Privducai
//
//  Created by Eddy Barraud on 27/03/2026.
//

import Foundation

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

    nonisolated static let `default` = RAGSelectionOptions(
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

        var ranked: [RankedRAGChunk] = []
        ranked.reserveCapacity(chunks.count)
        for chunk in chunks {
            let score = relevanceScore(text: chunk.text, query: query, options: options)
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
        let separator = "\n\n---\n\n"
        for rankedChunk in ranked {
            let chunkEntry = "Source: \(rankedChunk.chunk.source)\n\(rankedChunk.chunk.text)"
            let separatorChars = selected.isEmpty ? 0 : separator.count
            if currentChars + separatorChars + chunkEntry.count > maxContextChars {
                continue
            }
            selected.append(chunkEntry)
            currentChars += separatorChars + chunkEntry.count
        }

        if selected.isEmpty, let first = ranked.first {
            let fallback = "Source: \(first.chunk.source)\n\(first.chunk.text)"
            return RAGSelectionResult(
                selectedContext: String(fallback.prefix(max(options.minimumFallbackContextCharacters, maxContextChars))),
                rankedChunks: ranked
            )
        }

        return RAGSelectionResult(
            selectedContext: selected.joined(separator: separator),
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
        let title = isFrench ? "\n\n## Top 3 extraits pertinents :\n\n" : "\n\n## Top 3 relevant chunks:\n\n"
        let pageLabel = "PDF Page"

        let lines = chunks.enumerated().flatMap { index, ranked -> [String] in
            var row: [String] = []
            
            if let url = ranked.chunk.url {
                row.append("\(index + 1)- [\(url)](\(url)) \n")
            }
            if let page = ranked.chunk.pdfPage {
                row.append("\(index + 1)- Source: \(ranked.chunk.source)")
                row.append("   \(pageLabel): \(page) \n")
            }
            return row
        }

        return "\n\n\(title)\n" + lines.joined(separator: "\n")
    }
}
