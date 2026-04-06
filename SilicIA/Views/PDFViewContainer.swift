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
            if let pdfURL = pdfURL {
                pdfDocument = PDFDocument(url: pdfURL)
                pageCount = pdfDocument?.pageCount ?? 0
            }
        }
    }

    private func previousPage() {
        currentPage = max(1, currentPage - 1)
        onPageChanged(currentPage)
    }

    private func nextPage() {
        currentPage += 1
        onPageChanged(currentPage)
    }
}

/// SwiftUI wrapper for PDFKit's PDFView.
#if os(macOS)
struct PDFViewRepresentable: NSViewRepresentable {
    let pdfDocument: PDFKit.PDFDocument
    @Binding var currentPage: Int
    let onPageChanged: (Int) -> Void

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = pdfDocument
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if currentPage > 0, currentPage <= (pdfDocument.pageCount) {
            if let page = pdfDocument.page(at: currentPage - 1) {
                pdfView.go(to: page)
            }
        }
    }
}
#elseif canImport(UIKit)
struct PDFViewRepresentable: UIViewRepresentable {
    let pdfDocument: PDFKit.PDFDocument
    @Binding var currentPage: Int
    let onPageChanged: (Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = pdfDocument
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if currentPage > 0, currentPage <= (pdfDocument.pageCount) {
            if let page = pdfDocument.page(at: currentPage - 1) {
                pdfView.go(to: page)
            }
        }
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
