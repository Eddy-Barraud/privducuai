//
//  PDFDocumentView.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import SwiftUI
import PDFKit
import AppKit

struct PDFDocumentView: NSViewRepresentable {
    let pdfURL: URL?
    let onSelectionChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChanged: onSelectionChanged)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displaysPageBreaks = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.windowBackgroundColor
        context.coordinator.startObserving(pdfView: view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        guard context.coordinator.lastLoadedURL != pdfURL else { return }
        context.coordinator.lastLoadedURL = pdfURL

        guard let pdfURL else {
            nsView.document = nil
            onSelectionChanged("")
            return
        }

        let accessed = pdfURL.startAccessingSecurityScopedResource()
        let document = PDFDocument(url: pdfURL)
        if accessed {
            pdfURL.stopAccessingSecurityScopedResource()
        }

        nsView.document = document
        nsView.goToFirstPage(nil)
        onSelectionChanged("")
    }

    final class Coordinator {
        private let onSelectionChanged: (String) -> Void
        private var observerToken: NSObjectProtocol?
        var lastLoadedURL: URL?

        init(onSelectionChanged: @escaping (String) -> Void) {
            self.onSelectionChanged = onSelectionChanged
        }

        func startObserving(pdfView: PDFView) {
            observerToken = NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                guard let self, let pdfView else { return }
                let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.onSelectionChanged(text)
            }
        }

        deinit {
            if let observerToken {
                NotificationCenter.default.removeObserver(observerToken)
            }
        }
    }
}
