//
//  PDFViewerView.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import SwiftUI

/// Main container for split-screen PDF viewer (left) and chat (right).
struct PDFViewerView: View {
    @ObservedObject var pdfChatService: PDFChatService
    @Binding var sharedPDFs: [URL]
    @State private var currentPage = 1

    var body: some View {
        HStack(spacing: 0) {
            // Left: PDF Viewer
            PDFViewContainer(
                pdfURL: pdfChatService.currentPDF?.url,
                currentPage: $currentPage,
                highlightedChunks: pdfChatService.highlightedChunks,
                onPageChanged: { page in
                    currentPage = page
                }
            )
            .frame(minWidth: 300)

            Divider()

            // Right: Chat Interface
            PDFChatContentView(
                pdfChatService: pdfChatService,
                sharedPDFs: $sharedPDFs,
                onCitationTapped: { chunk in
                    pdfChatService.setHighlightedChunks([chunk])
                    // Navigate to the page if it's a PDF chunk
                    if let page = chunk.pdfPage {
                        currentPage = page
                    }
                }
            )
            .frame(minWidth: 300)
        }
    }
}

#Preview {
    @Previewable @StateObject var pdfChatService = PDFChatService()
    @Previewable @State var sharedPDFs: [URL] = []

    return PDFViewerView(
        pdfChatService: pdfChatService,
        sharedPDFs: $sharedPDFs
    )
}
