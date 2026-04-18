//
//  RAGContextService.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import Foundation

struct RAGChunk: Identifiable {
    let id = UUID()
    let source: String
    let text: String
    let url: String?
    let pdfPage: Int?
    let boostRankOne: Bool

    init(source: String, text: String, url: String? = nil, pdfPage: Int? = nil, boostRankOne: Bool = false) {
        self.source = source
        self.text = text
        self.url = url
        self.pdfPage = pdfPage
        self.boostRankOne = boostRankOne
    }
}

struct RAGChunker {
    private static let avgCharsPerToken = 3
    private static let whitespacePattern = "\\s+"
    private static let minimumChunkCharacters = 200

    func chunk(
        text: String,
        source: String,
        maxChunkTokens: Int,
        overlapTokens: Int,
        url: String? = nil,
        pdfPage: Int? = nil,
        boostRankOne: Bool = false
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
                chunks.append(RAGChunk(source: source, text: piece, url: url, pdfPage: pdfPage, boostRankOne: boostRankOne))
            }

            if end == cleanText.endIndex { break }
            start = cleanText.index(start, offsetBy: stride, limitedBy: cleanText.endIndex) ?? cleanText.endIndex
        }

        return chunks
    }
}

struct RAGSelectionOptions {
    let avgCharsPerToken: Int
    let instructionTokens: Int
    let promptOverheadTokens: Int
    let minContextTokens: Int
    let contextUtilizationFactor: Double
    let minimumFallbackContextCharacters: Int
    let longChunkCharacterThreshold: Int
    let longChunkBonusScore: Double
    let forcedRankOneBonus: Double

    nonisolated static let `default` = RAGSelectionOptions(
        avgCharsPerToken: TokenBudgeting.avgCharsPerToken,
        instructionTokens: TokenBudgeting.instructionTokens,
        promptOverheadTokens: TokenBudgeting.promptOverheadTokens,
        minContextTokens: TokenBudgeting.minContextTokens,
        contextUtilizationFactor: 0.8,
        minimumFallbackContextCharacters: 200,
        longChunkCharacterThreshold: 300,
        longChunkBonusScore: 0.2,
        forcedRankOneBonus: 1000
    )
}

struct RankedRAGChunk {
    let chunk: RAGChunk
    let relevanceScore: Double
}

struct RAGSelectionResult {
    let selectedContext: String
    let rankedChunks: [RankedRAGChunk]

    var topChunks: [RankedRAGChunk] {
        Array(rankedChunks.prefix(3))
    }
}

actor RAGContextService {
    func selectContext(
        chunks: [RAGChunk],
        query: String,
        maxOutputTokens: Int,
        contextUtilizationFactor: Double? = nil,
        options: RAGSelectionOptions = .default
    ) async -> RAGSelectionResult {
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

        var ranked: [RankedRAGChunk] = []
        ranked.reserveCapacity(chunks.count)
        for chunk in chunks {
            let score = relevanceScore(chunk: chunk, query: query, options: options)
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
            let prefix = rankedChunk.chunk.boostRankOne ? "[RANK-1 Selection]\n" : ""
            let chunkEntry = "\(prefix)Source: \(rankedChunk.chunk.source)\n\(rankedChunk.chunk.text)"
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

    private func relevanceScore(chunk: RAGChunk, query: String, options: RAGSelectionOptions) -> Double {
        let queryWords = Set(tokenize(query).filter { $0.count > 2 })
        var score = 0.0
        if !queryWords.isEmpty {
            let textWords = Set(tokenize(chunk.text))
            for word in queryWords where textWords.contains(word) {
                score += 1.0
            }
        }

        if chunk.text.count > options.longChunkCharacterThreshold {
            score += options.longChunkBonusScore
        }

        if options.forcedRankOneBonus > 0,
           chunk.boostRankOne {
            score += options.forcedRankOneBonus
        }

        return score
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

}

enum RAGCitationFormatter {
    static func citationBlock(from chunks: [RankedRAGChunk], language: ModelLanguage? = nil) -> String {
        guard !chunks.isEmpty else { return "" }

        let pageLabel = language == .french ? "Page PDF" : "PDF Page"
        let forcedLabel = language == .french ? "Contexte prioritaire" : "Priority Context"

        let lines = chunks.enumerated().map { index, ranked -> String in
            var itemLines: [String] = []
            itemLines.append("\(index + 1). \(ranked.chunk.source)")
            if let page = ranked.chunk.pdfPage {
                itemLines.append("   \(pageLabel): \(page)")
            }
            if ranked.chunk.boostRankOne {
                itemLines.append("   \(forcedLabel): rank 1")
            }
            return itemLines.joined(separator: "\n")
        }

        return lines.joined(separator: "\n\n")
    }
}
