//
//  PDFHighlightManager.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import Foundation
import Combine

/// Manages PDF highlighting state for cited passages.
@MainActor
final class PDFHighlightManager: ObservableObject {
    @Published var highlightedChunks: [RAGChunk] = []
    @Published var selectedChunkIndex: Int?

    /// Highlights a specific chunk and updates UI.
    func highlightChunk(_ chunk: RAGChunk) {
        highlightedChunks = [chunk]
        selectedChunkIndex = 0
    }

    /// Highlights multiple chunks.
    func highlightChunks(_ chunks: [RAGChunk]) {
        highlightedChunks = chunks
    }

    /// Clears all highlights.
    func clearHighlights() {
        highlightedChunks = []
        selectedChunkIndex = nil
    }

    /// Selects a specific chunk to highlight by index.
    func selectChunk(at index: Int) {
        guard index >= 0 && index < highlightedChunks.count else { return }
        selectedChunkIndex = index
    }

    /// Gets the currently selected chunk, if any.
    var selectedChunk: RAGChunk? {
        guard let index = selectedChunkIndex,
              index >= 0 && index < highlightedChunks.count else {
            return nil
        }
        return highlightedChunks[index]
    }
}
