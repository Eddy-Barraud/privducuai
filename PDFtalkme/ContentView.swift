//
//  ContentView.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import SwiftUI
import UniformTypeIdentifiers
import LaTeXSwiftUI

struct ContentView: View {
    @StateObject private var chatService = PDFChatService()
    @StateObject private var openRouter = PDFOpenRouter.shared
    @State private var settings = AppSettings.load()
    @State private var documents: [PDFDocumentTab] = []
    @State private var selectedTabID: UUID?
    @State private var selectedSelectionText = ""
    @State private var prioritizedSelectionText: String?
    @State private var showImporter = false
    @State private var composerInput = ""
    @State private var isDropTargeted = false
    @FocusState private var isComposerFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var selectedPDFURL: URL? {
        guard let selectedTabID,
              let tab = documents.first(where: { $0.id == selectedTabID }) else {
            return nil
        }
        return tab.url
    }

    var body: some View {
        HSplitView {
            pdfPane
                .frame(minWidth: 720, idealWidth: 940)

            chatPane
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 560)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true,
            onCompletion: handlePDFImport
        )
        .onChange(of: settings) {
            settings.save()
        }
        .onChange(of: selectedTabID) {
            activateSelectedTab()
        }
        .onChange(of: openRouter.signal) {
            consumePendingOpenRequests()
        }
        .task {
            consumePendingOpenRequests()
        }
    }

    private var pdfPane: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image("PDFtalkmeLogo")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 19, height: 19)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text("PDFtalkme")
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        showImporter = true
                    } label: {
                        Label("Open PDF", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                if !documents.isEmpty {
                    tabStrip
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                Divider()

                PDFDocumentView(pdfURL: selectedPDFURL) { text in
                    selectedSelectionText = text
                }
                .overlay {
                    if selectedPDFURL == nil {
                        ContentUnavailableView(
                            "Open or drop a PDF",
                            systemImage: "doc.richtext",
                            description: Text("Use Open PDF or drag and drop a PDF here.")
                        )
                    }
                }
            }

            if shouldShowSelectionPopup {
                selectionPopup
                    .padding(.top, 18)
                    .padding(.trailing, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .pdf], isTargeted: $isDropTargeted, perform: handlePDFDrop)
        .animation(.easeInOut(duration: 0.18), value: shouldShowSelectionPopup)
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(documents) { tab in
                    HStack(spacing: 6) {
                        Button {
                            selectedTabID = tab.id
                            selectedSelectionText = ""
                            prioritizedSelectionText = nil
                        } label: {
                            Text(tab.title)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)

                        Button {
                            closeTab(id: tab.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        selectedTabID == tab.id
                        ? Color.accentColor.opacity(0.18)
                        : Color(nsColor: .controlBackgroundColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var chatPane: some View {
        VStack(spacing: 12) {
            chatHeader

            if let message = chatService.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            messageList

            if let prioritizedSelectionText,
               !prioritizedSelectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prioritizedBadge(text: prioritizedSelectionText)
            }

            composer
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var chatHeader: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image("PDFtalkmeLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("PDFtalkme")
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                Spacer()

                Button {
                    chatService.clearInMemoryConversation()
                } label: {
                    Label("New Chat", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    chatService.clearHistoryForActiveDocument()
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selectedPDFURL == nil)
            }

            HStack(spacing: 10) {
                Picker("Language", selection: $settings.language) {
                    ForEach(ModelLanguage.allCases, id: \.self) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Temp \(String(format: "%.2f", settings.temperature))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: $settings.temperature, in: AppSettings.temperatureRange, step: 0.05)
                }
            }
        }
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if chatService.messages.isEmpty {
                    Text("Ask questions about the active PDF tab. Starred selections are forced as rank-1 retrieval context.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(chatService.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.role == .user ? "You" : "Assistant")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        renderedMessageContent(message)
                            .textSelection(.enabled)

                        if let citations = message.citations,
                           !citations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                            if let attributed = try? AttributedString(markdown: citations) {
                                Text(attributed)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .tint(.accentColor)
                                    .textSelection(.enabled)
                            } else {
                                Text(citations)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        message.role == .user
                        ? Color.accentColor.opacity(0.15)
                        : Color(nsColor: .textBackgroundColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if chatService.isResponding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking...")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func renderedMessageContent(_ message: PDFChatMessage) -> some View {
        if message.role == .assistant {
            LaTeX(message.content)
                .font(.body)
                .foregroundColor(colorScheme == .dark ? .white : .black)
        } else {
            Text(message.content)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this PDF", text: $composerInput, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($isComposerFocused)
                .onSubmit {
                    submit()
                }

            Button("Send") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                composerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                chatService.isResponding
            )
        }
    }

    private var selectionPopup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Selected passage", systemImage: "star.fill")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(selectionPreview(selectedSelectionText))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)

            Button {
                prioritizedSelectionText = selectedSelectionText
            } label: {
                Label("Ask about this selection", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 8)
    }

    private func prioritizedBadge(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "star.circle.fill")
                .foregroundColor(.yellow)

            Text("Rank-1 context from selection")
                .font(.caption)
                .fontWeight(.semibold)

            Text(selectionPreview(text))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                prioritizedSelectionText = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var shouldShowSelectionPopup: Bool {
        !selectedSelectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectionPreview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 160 {
            return compact
        }
        let end = compact.index(compact.startIndex, offsetBy: 160)
        return String(compact[..<end]) + "..."
    }

    private func submit() {
        let trimmed = composerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerInput = ""

        Task {
            await chatService.sendMessage(
                trimmed,
                pdfURL: selectedPDFURL,
                prioritizedSelectionText: prioritizedSelectionText,
                settings: settings
            )
        }
    }

    private func handlePDFImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        addPDFTabs(urls)
    }

    private func handlePDFDrop(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !candidates.isEmpty else { return false }

        for provider in candidates {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    guard let url,
                          let stableURL = copyDroppedPDFToTemporaryStorage(url) else { return }
                    Task { @MainActor in
                        addPDFTabs([stableURL])
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let fileURL: URL?
                    if let data = item as? Data {
                        fileURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                    } else if let url = item as? URL {
                        fileURL = url
                    } else if let nsURL = item as? NSURL {
                        fileURL = nsURL as URL
                    } else {
                        fileURL = nil
                    }

                    guard let fileURL,
                          fileURL.pathExtension.lowercased() == "pdf" else {
                        return
                    }
                    Task { @MainActor in
                        addPDFTabs([fileURL])
                    }
                }
            }
        }
        return true
    }

    private func addPDFTabs(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            if let existing = documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                selectedTabID = existing.id
                continue
            }
            let tab = PDFDocumentTab(url: url)
            documents.append(tab)
            selectedTabID = tab.id
        }

        if selectedTabID == nil, let first = documents.first {
            selectedTabID = first.id
        }

        selectedSelectionText = ""
        prioritizedSelectionText = nil
        activateSelectedTab()
    }

    private func copyDroppedPDFToTemporaryStorage(_ sourceURL: URL) -> URL? {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("PDFtalkmeDroppedPDFs", isDirectory: true)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let preferredName = sourceURL.lastPathComponent.isEmpty ? "dropped.pdf" : sourceURL.lastPathComponent
            let baseName = (preferredName as NSString).deletingPathExtension
            let ext = (preferredName as NSString).pathExtension.isEmpty ? "pdf" : (preferredName as NSString).pathExtension
            let destination = folder.appendingPathComponent("\(baseName)-\(UUID().uuidString).\(ext)")
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            #if DEBUG
            print("[ContentView] Failed to persist dropped PDF: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private func closeTab(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents.remove(at: index)

        if selectedTabID == id {
            selectedTabID = documents.indices.contains(index)
                ? documents[index].id
                : documents.last?.id
            selectedSelectionText = ""
            prioritizedSelectionText = nil
            activateSelectedTab()
        }
    }

    private func activateSelectedTab() {
        selectedSelectionText = ""
        prioritizedSelectionText = nil
        chatService.activateDocument(selectedPDFURL)
    }

    private func consumePendingOpenRequests() {
        let incoming = openRouter.drain()
        guard !incoming.isEmpty else { return }
        addPDFTabs(incoming)
    }
}

private struct PDFDocumentTab: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let title: String

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }
}

#Preview {
    ContentView()
        .frame(width: 1400, height: 900)
}
