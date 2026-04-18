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
    let focusedCitationRequest: PDFCitationFocusRequest?
    let findRequest: PDFFindRequest?
    let onSelectionChanged: (String) -> Void
    let onDropPDFURLs: ([URL]) -> Void
    let onSidebarDataUpdated: ([PDFOutlineItem], [PDFPagePreview], Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelectionChanged: onSelectionChanged,
            onDropPDFURLs: onDropPDFURLs,
            onSidebarDataUpdated: onSidebarDataUpdated
        )
    }

    func makeNSView(context: Context) -> PDFDropContainerView {
        let container = PDFDropContainerView()
        let view = container.pdfView
        view.autoScales = true
        view.displaysPageBreaks = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.windowBackgroundColor

        container.onDropPDFURLs = { urls in
            context.coordinator.handleDropped(urls: urls)
        }
        context.coordinator.startObserving(pdfView: view)
        return container
    }

    func updateNSView(_ nsView: PDFDropContainerView, context: Context) {
        let pdfView = nsView.pdfView
        nsView.onDropPDFURLs = { urls in
            context.coordinator.handleDropped(urls: urls)
        }

        if context.coordinator.lastLoadedURL != pdfURL {
            context.coordinator.lastLoadedURL = pdfURL

            guard let pdfURL else {
                pdfView.document = nil
                onSelectionChanged("")
                return
            }

            let accessed = pdfURL.startAccessingSecurityScopedResource()
            let loadedDocument = PDFDocument(url: pdfURL)
            if accessed {
                pdfURL.stopAccessingSecurityScopedResource()
            }

            pdfView.document = loadedDocument
            pdfView.goToFirstPage(nil)
            onSelectionChanged("")
            context.coordinator.lastFocusRequestID = nil
            context.coordinator.lastFindRequestID = nil
            context.coordinator.findResults = []
            context.coordinator.findIndex = -1
            if let loadedDocument {
                context.coordinator.refreshSidebarData(from: loadedDocument)
            }
        }

        if context.coordinator.lastFocusRequestID != focusedCitationRequest?.requestID {
            context.coordinator.lastFocusRequestID = focusedCitationRequest?.requestID
            context.coordinator.focus(on: focusedCitationRequest?.citation, in: pdfView)
        }

        if context.coordinator.lastFindRequestID != findRequest?.requestID {
            context.coordinator.lastFindRequestID = findRequest?.requestID
            context.coordinator.runFind(findRequest, in: pdfView)
        }
    }

    final class Coordinator {
        private let onSelectionChanged: (String) -> Void
        private let onDropPDFURLs: ([URL]) -> Void
        private let onSidebarDataUpdated: ([PDFOutlineItem], [PDFPagePreview], Int) -> Void
        private var observerToken: NSObjectProtocol?
        private var highlightWorkItem: DispatchWorkItem?

        var lastLoadedURL: URL?
        var lastFocusRequestID: UUID?
        var lastFindRequestID: UUID?
        var lastFindQuery: String = ""
        var findResults: [PDFSelection] = []
        var findIndex: Int = -1

        init(
            onSelectionChanged: @escaping (String) -> Void,
            onDropPDFURLs: @escaping ([URL]) -> Void,
            onSidebarDataUpdated: @escaping ([PDFOutlineItem], [PDFPagePreview], Int) -> Void
        ) {
            self.onSelectionChanged = onSelectionChanged
            self.onDropPDFURLs = onDropPDFURLs
            self.onSidebarDataUpdated = onSidebarDataUpdated
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

        func handleDropped(urls: [URL]) {
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return }
            onDropPDFURLs(pdfs)
        }

        func focus(on citation: PDFCitation?, in pdfView: PDFView) {
            highlightWorkItem?.cancel()
            guard let citation,
                  let pageNumber = citation.page,
                  let document = pdfView.document,
                  pageNumber > 0,
                  pageNumber <= document.pageCount,
                  let page = document.page(at: pageNumber - 1) else {
                return
            }

            pdfView.go(to: page)

            let pageSelection: PDFSelection?
            if let snippet = citation.snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                pageSelection = page.selection(for: NSRange(location: 0, length: page.string?.utf16.count ?? 0))?
                    .selectionsByLine()
                    .first(where: { selection in
                        selection.string?.localizedCaseInsensitiveContains(snippet) == true
                    })
            } else {
                pageSelection = nil
            }

            if let pageSelection {
                pdfView.setCurrentSelection(pageSelection, animate: true)
                pdfView.go(to: pageSelection)
                let workItem = DispatchWorkItem { [weak pdfView] in
                    pdfView?.clearSelection()
                }
                highlightWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
            }
        }

        func runFind(_ request: PDFFindRequest?, in pdfView: PDFView) {
            guard let request else {
                findResults = []
                findIndex = -1
                lastFindQuery = ""
                pdfView.clearSelection()
                return
            }

            guard let document = pdfView.document else {
                return
            }

            let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                findResults = []
                findIndex = -1
                lastFindQuery = ""
                pdfView.clearSelection()
                return
            }

            if findResults.isEmpty || lastFindQuery.caseInsensitiveCompare(query) != .orderedSame {
                findResults = document.findString(query, withOptions: NSString.CompareOptions.caseInsensitive)
                lastFindQuery = query
                findIndex = request.direction == .next ? 0 : max(findResults.count - 1, 0)
            } else if request.direction == .next {
                let next = findIndex + 1
                findIndex = next >= findResults.count ? 0 : next
            } else {
                let previous = findIndex - 1
                findIndex = previous < 0 ? max(findResults.count - 1, 0) : previous
            }

            guard findResults.indices.contains(findIndex) else {
                pdfView.clearSelection()
                return
            }

            let selection = findResults[findIndex]
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
        }

        func refreshSidebarData(from document: PDFDocument) {
            let outline = extractOutlineItems(from: document)
            let previews = extractPagePreviews(from: document)
            onSidebarDataUpdated(outline, previews, document.pageCount)
        }

        private func extractOutlineItems(from document: PDFDocument) -> [PDFOutlineItem] {
            guard let root = document.outlineRoot else { return [] }
            var items: [PDFOutlineItem] = []

            func walk(node: PDFOutline, level: Int) {
                for index in 0..<node.numberOfChildren {
                    guard let child = node.child(at: index) else { continue }

                    let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let page: Int?
                    if let destinationPage = child.destination?.page {
                        page = document.index(for: destinationPage) + 1
                    } else if let gotoAction = child.action as? PDFActionGoTo {
                        if let destinationPage = gotoAction.destination.page {
                            page = document.index(for: destinationPage) + 1
                        } else {
                            page = nil
                        }
                    } else {
                        page = nil
                    }

                    if !title.isEmpty, let page {
                        items.append(PDFOutlineItem(title: title, page: page, level: level))
                    }

                    walk(node: child, level: level + 1)
                }
            }

            walk(node: root, level: 0)
            return items
        }

        private func extractPagePreviews(from document: PDFDocument) -> [PDFPagePreview] {
            var previews: [PDFPagePreview] = []
            previews.reserveCapacity(document.pageCount)

            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let thumb = page.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
                previews.append(PDFPagePreview(page: pageIndex + 1, thumbnail: thumb))
            }

            return previews
        }

        deinit {
            if let observerToken {
                NotificationCenter.default.removeObserver(observerToken)
            }
        }
    }
}

final class PDFDropContainerView: NSView {
    let pdfView = DroppablePDFView()
    var onDropPDFURLs: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        pdfView.onDropPDFURLs = { [weak self] urls in
            self?.onDropPDFURLs?(urls)
        }
    }
}

final class DroppablePDFView: PDFView {
    var onDropPDFURLs: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasAcceptablePDF(in: sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasAcceptablePDF(in: sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasAcceptablePDF(in: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = droppedPDFURLs(from: sender), !urls.isEmpty else {
            return false
        }
        onDropPDFURLs?(urls)
        return true
    }

    private func hasAcceptablePDF(in draggingInfo: NSDraggingInfo) -> Bool {
        guard let urls = droppedPDFURLs(from: draggingInfo) else { return false }
        return !urls.isEmpty
    }

    private func droppedPDFURLs(from draggingInfo: NSDraggingInfo) -> [URL]? {
        let pasteboard = draggingInfo.draggingPasteboard
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return nil
        }
        return objects.filter { $0.pathExtension.lowercased() == "pdf" }
    }
}
