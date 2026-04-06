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
            if !chunks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(language == .french ? "Sources RAG" : "RAG Sources")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(Array(chunks.enumerated()), id: \.element.id) { index, chunk in
                        Button(action: {
                            onCitationTapped(chunk)
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("\(index + 1). \(chunk.source)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Spacer()

                                    if let page = chunk.pdfPage {
                                        Text("\(language == .french ? "Page" : "Page") \(page)")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue)
                                            .cornerRadius(4)
                                    }
                                }

                                Text(chunkPreview(for: chunk.text))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(controlBackgroundColor.opacity(0.8))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(controlBackgroundColor)
                .cornerRadius(6)
            } else if let citations, !citations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(citations)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(controlBackgroundColor)
                    .cornerRadius(6)
            }
        }
    }

    private func chunkPreview(for text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxPreviewLength = 220
        if normalized.count <= maxPreviewLength {
            return normalized
        }
        return String(normalized.prefix(maxPreviewLength)) + "…"
    }
}

#Preview {
    @Previewable @State var language: ModelLanguage = .english

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
