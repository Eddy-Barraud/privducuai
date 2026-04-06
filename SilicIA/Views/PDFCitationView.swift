//
//  PDFCitationView.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Renders PDF citations as interactive links with page navigation.
struct PDFCitationView: View {
    let citations: String?
    let chunks: [RAGChunk]
    let onCitationTapped: (RAGChunk) -> Void
    let language: ModelLanguage

    private var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let citations = citations, !citations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language == .french ? "Sources citées" : "Cited Sources")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    // Parse and render each citation
                    ForEach(parseCitations(citations), id: \.self) { citationLine in
                        CitationLineView(
                            text: citationLine,
                            chunks: chunks,
                            language: language,
                            onCitationTapped: onCitationTapped
                        )
                    }
                }
                .padding(8)
                .background(controlBackgroundColor)
                .cornerRadius(6)
            }
        }
    }

    private func parseCitations(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }
}

/// Renders a single citation line with interactive page number.
struct CitationLineView: View {
    let text: String
    let chunks: [RAGChunk]
    let language: ModelLanguage
    let onCitationTapped: (RAGChunk) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Extract page number if present
            if let pageNumber = extractPageNumber(from: text) {
                let sourceText = text.components(separatedBy: " — ")[0]

                HStack(spacing: 8) {
                    Text(sourceText)
                        .font(.caption)
                        .foregroundStyle(.primary)

                    Spacer()

                    Button(action: {
                        // Find matching chunk and trigger highlight
                        if let chunk = findChunkForPage(pageNumber) {
                            onCitationTapped(chunk)
                        }
                    }) {
                        Text("Page \(pageNumber)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHovering = hovering
                    }
                }
            } else {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .contentShape(Rectangle())
    }

    private func extractPageNumber(from text: String) -> Int? {
        let pattern = language == .french ? "Page (\\d+)" : "Page (\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return Int(text[range])
        }
        return nil
    }

    private func findChunkForPage(_ pageNumber: Int) -> RAGChunk? {
        chunks.first { $0.pdfPage == pageNumber }
    }
}

#Preview {
    @State var language: ModelLanguage = .english

    return VStack {
        PDFCitationView(
            citations: "1. example.pdf — Page 3\n\n2. example.pdf — Page 5",
            chunks: [
                RAGChunk(source: "example.pdf", text: "Sample text", url: nil, pdfPage: 3),
                RAGChunk(source: "example.pdf", text: "More text", url: nil, pdfPage: 5)
            ],
            onCitationTapped: { _ in },
            language: language
        )
        .padding()

        Spacer()
    }
}
