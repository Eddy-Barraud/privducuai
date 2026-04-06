//
//  PDFViewContainer.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import SwiftUI
import PDFKit
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Wraps PDFKit's PDFView with navigation and highlighting support.
struct PDFViewContainer: View {
    let pdfURL: URL?
    @Binding var currentPage: Int
    let highlightedChunks: [RAGChunk]
    let onPageChanged: (Int) -> Void

    @State private var pdfDocument: PDFKit.PDFDocument?
    @State private var pageCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Page navigation toolbar
            HStack(spacing: 12) {
                Button(action: { previousPage() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage <= 1)

                Spacer()

                Text("Page \(currentPage) of \(pageCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: { nextPage() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= pageCount)
            }
            .padding(8)
            .background(Color(.init(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 1.0)))

            // PDF view
            if let pdfDocument = pdfDocument {
                PDFViewRepresentable(
                    pdfDocument: pdfDocument,
                    currentPage: $currentPage,
                    highlightedChunks: highlightedChunks,
                    onPageChanged: onPageChanged
                )
            } else {
                VStack {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No PDF loaded")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.init(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 1.0)))
            }
        }
        .onAppear {
            loadDocument(from: pdfURL)
        }
        .onChange(of: pdfURL) {
            loadDocument(from: pdfURL)
        }
    }

    private func previousPage() {
        guard pageCount > 0 else { return }
        currentPage = max(1, min(pageCount, currentPage - 1))
        onPageChanged(currentPage)
    }

    private func nextPage() {
        guard pageCount > 0 else { return }
        currentPage = max(1, min(pageCount, currentPage + 1))
        onPageChanged(currentPage)
    }

    private func loadDocument(from url: URL?) {
        guard let url else {
            pdfDocument = nil
            pageCount = 0
            currentPage = 1
            onPageChanged(currentPage)
            return
        }

        let document = PDFDocument(url: url)
        pdfDocument = document
        pageCount = document?.pageCount ?? 0
        currentPage = pageCount > 0 ? 1 : 1
        onPageChanged(currentPage)
    }
}

private enum PDFHighlightConstants {
    static let annotationOwner = "SilicIA-RAG-Chunk"
    static let maxSnippetLength = 120
}

final class PDFViewCoordinator: NSObject {
    private let setCurrentPage: (Int) -> Void
    private let onPageChanged: (Int) -> Void
    private var pageObserver: NSObjectProtocol?
    private var lastHighlightedChunkID: UUID?

    init(setCurrentPage: @escaping (Int) -> Void, onPageChanged: @escaping (Int) -> Void) {
        self.setCurrentPage = setCurrentPage
        self.onPageChanged = onPageChanged
    }

    deinit {
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
    }

    func startObserving(_ pdfView: PDFView) {
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }

        pageObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            guard
                let self,
                let page = pdfView.currentPage,
                let document = pdfView.document
            else {
                return
            }

            let pageIndex = document.index(for: page) + 1
            self.setCurrentPage(pageIndex)
            self.onPageChanged(pageIndex)
        }
    }

    func syncViewState(
        pdfView: PDFView,
        document: PDFKit.PDFDocument,
        currentPage: Int,
        highlightedChunks: [RAGChunk]
    ) {
        if pdfView.document !== document {
            pdfView.document = document
        }

        let clampedPage = max(1, min(currentPage, document.pageCount))
        if let page = document.page(at: clampedPage - 1), page != pdfView.currentPage {
            pdfView.go(to: page)
        }

        applyHighlight(for: highlightedChunks.first, in: pdfView, document: document)
    }

    private func applyHighlight(for chunk: RAGChunk?, in pdfView: PDFView, document: PDFKit.PDFDocument) {
        guard let chunk else {
            clearManagedHighlights(in: document)
            lastHighlightedChunkID = nil
            return
        }

        if lastHighlightedChunkID == chunk.id {
            return
        }

        clearManagedHighlights(in: document)
        defer { lastHighlightedChunkID = chunk.id }

        guard
            let pageNumber = chunk.pdfPage,
            pageNumber > 0,
            pageNumber <= document.pageCount,
            let page = document.page(at: pageNumber - 1),
            let pageText = page.string,
            let range = bestRangeForChunk(chunk.text, in: pageText)
        else {
            return
        }

        guard let selection = page.selection(for: range) else {
            return
        }

        let annotationBounds = selection.bounds(for: page).insetBy(dx: -1, dy: -1)
        let annotation = PDFAnnotation(bounds: annotationBounds, forType: .highlight, withProperties: nil)
        #if os(macOS)
        annotation.color = NSColor.systemYellow.withAlphaComponent(0.4)
        #elseif canImport(UIKit)
        annotation.color = UIColor.systemYellow.withAlphaComponent(0.4)
        #endif
        annotation.userName = PDFHighlightConstants.annotationOwner
        page.addAnnotation(annotation)

        pdfView.go(to: page)
    }

    private func clearManagedHighlights(in document: PDFKit.PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let annotationsToRemove = page.annotations.filter { annotation in
                annotation.userName == PDFHighlightConstants.annotationOwner
            }
            for annotation in annotationsToRemove {
                page.removeAnnotation(annotation)
            }
        }
    }

    private func bestRangeForChunk(_ chunkText: String, in pageText: String) -> NSRange? {
        let normalizedChunk = chunkText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChunk.isEmpty else { return nil }

        let candidates: [String] = [
            normalizedChunk,
            String(normalizedChunk.prefix(PDFHighlightConstants.maxSnippetLength)),
            String(normalizedChunk.prefix(80)),
            String(normalizedChunk.prefix(50))
        ]

        let pageNSString = pageText as NSString
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let range = pageNSString.range(of: trimmed, options: [.caseInsensitive])
            if range.location != NSNotFound {
                return range
            }
        }

        return nil
    }
}

/// SwiftUI wrapper for PDFKit's PDFView.
#if os(macOS)
struct PDFViewRepresentable: NSViewRepresentable {
    let pdfDocument: PDFKit.PDFDocument
    @Binding var currentPage: Int
    let highlightedChunks: [RAGChunk]
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(
            setCurrentPage: { page in
                currentPage = page
            },
            onPageChanged: onPageChanged
        )
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = pdfDocument
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.allowsDragging = true
        context.coordinator.startObserving(pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.syncViewState(
            pdfView: pdfView,
            document: pdfDocument,
            currentPage: currentPage,
            highlightedChunks: highlightedChunks
        )
    }
}
#elseif canImport(UIKit)
struct PDFViewRepresentable: UIViewRepresentable {
    let pdfDocument: PDFKit.PDFDocument
    @Binding var currentPage: Int
    let highlightedChunks: [RAGChunk]
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(
            setCurrentPage: { page in
                currentPage = page
            },
            onPageChanged: onPageChanged
        )
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = pdfDocument
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.allowsDragging = true
        context.coordinator.startObserving(pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.syncViewState(
            pdfView: pdfView,
            document: pdfDocument,
            currentPage: currentPage,
            highlightedChunks: highlightedChunks
        )
    }
}
#endif

#Preview {
    @State var currentPage = 1

    return PDFViewContainer(
        pdfURL: nil,
        currentPage: $currentPage,
        highlightedChunks: [],
        onPageChanged: { _ in }
    )
}
