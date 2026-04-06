//
//  PDFAnswerAnalyzer.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import Foundation

/// Analyzes PDF chat responses to extract page citations and create interactive links.
struct PDFAnswerAnalyzer {
    /// Extracts page numbers mentioned in the response text.
    static func extractPageCitations(from text: String) -> [Int] {
        var pages: Set<Int> = []

        // Pattern 1: "page X" or "pages X"
        let pattern1 = "page[s]?\\s+(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern1, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                if let match = match, let range = Range(match.range(at: 1), in: text) {
                    if let pageNum = Int(text[range]) {
                        pages.insert(pageNum)
                    }
                }
            }
        }

        // Pattern 2: "Page X" in citations like "— Page X"
        let pattern2 = "—\\s*Page\\s+(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern2, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                if let match = match, let range = Range(match.range(at: 1), in: text) {
                    if let pageNum = Int(text[range]) {
                        pages.insert(pageNum)
                    }
                }
            }
        }

        return Array(pages).sorted()
    }

    /// Creates clickable page links with markdown format.
    static func enhanceWithPageLinks(
        text: String,
        pageNumbers: [Int]
    ) -> String {
        var enhanced = text

        // Replace "page X" with "[page X](#page-X)" style links
        for pageNum in pageNumbers {
            let pattern = "(?i)(page[s]?\\s+\(pageNum)(?!\\d))"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(enhanced.startIndex..., in: enhanced)
                enhanced = regex.stringByReplacingMatches(
                    in: enhanced,
                    options: [],
                    range: range,
                    withTemplate: "[page \\1](#page-\(pageNum))"
                )
            }
        }

        return enhanced
    }

    /// Analyzes citations in the response and returns structured data.
    static func analyzeCitations(
        in text: String,
        sourceChunks: [RAGChunk]
    ) -> PDFCitationAnalysis {
        let pageNumbers = extractPageCitations(from: text)
        let citedChunks = sourceChunks.filter { chunk in
            guard let page = chunk.pdfPage else { return false }
            return pageNumbers.contains(page)
        }

        return PDFCitationAnalysis(
            extractedPageNumbers: pageNumbers,
            citedChunks: citedChunks,
            enhancedText: enhanceWithPageLinks(text: text, pageNumbers: pageNumbers)
        )
    }
}

/// Structured result of PDF citation analysis.
struct PDFCitationAnalysis {
    /// Page numbers extracted from the response text.
    let extractedPageNumbers: [Int]
    /// RAGChunks that correspond to cited pages.
    let citedChunks: [RAGChunk]
    /// Response text with enhanced markdown links for pages.
    let enhancedText: String
}
