//
//  PDFDocument.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import Foundation

/// Represents a loaded PDF document with extracted content and metadata.
struct PDFDocumentInfo {
    /// URL/path to the PDF file.
    let url: URL
    /// Display name of the PDF file.
    let fileName: String
    /// Total number of pages in the PDF.
    var pageCount: Int
    /// Extracted and chunked content from PDF with page metadata.
    var extractedChunks: [RAGChunk] = []
    /// Current loading status of the document.
    var loadingStatus: LoadingStatus = .idle

    enum LoadingStatus: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    init(url: URL) {
        self.url = url
        self.fileName = url.lastPathComponent
        self.pageCount = 0
    }
}

