//
//  ChatView.swift
//  Privducai
//
//  Created by Eddy Barraud on 27/03/2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Chat UI that sends prompts and contextual documents to `ChatService`.
struct ChatView: View {
    @Binding var sharedURLs: [String]
    @Binding var sharedPDFs: [URL]

    @StateObject private var chatService = ChatService()

    @State private var messageInput = ""
    @State private var showFileImporter = false
    @State private var contextSources: [ContextSource] = [ContextSource(kind: .url(text: ""))]
    @State private var preanalysisTask: Task<Void, Never>?

    /// Renders chat transcript, composer, and context inputs.
    var body: some View {
        VStack(spacing: 12) {
            messagesView

            if let errorMessage = chatService.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            composerView

            contextBoxView
        }
        .padding()
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { @MainActor in
                appendPDFSources(urls)
            }
        }
        .onAppear {
            mergeSharedInputsIfNeeded()
        }
        .onChange(of: sharedURLs) {
            mergeSharedInputsIfNeeded()
        }
        .onChange(of: sharedPDFs) {
            mergeSharedInputsIfNeeded()
        }
    }

    /// Renders message history and in-progress state.
    private var messagesView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if chatService.messages.isEmpty {
                    Text("Start a chat conversation with the foundation model.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(chatService.messages) { message in
                    HStack {
                        if message.role == .assistant { Spacer(minLength: 40) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.role == .user ? "You" : "Assistant")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            renderedMessageContent(message)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .background(
                            message.role == .user
                            ? Color.accentColor.opacity(0.15)
                            : Color(NSColor.controlBackgroundColor)
                        )
                        .cornerRadius(10)
                        if message.role == .user { Spacer(minLength: 40) }
                    }
                }

                if chatService.isResponding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking…")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
    }

    /// Renders assistant replies as Markdown when possible, with plaintext fallback.
    private func renderedMessageContent(_ message: ChatMessage) -> Text {
        guard message.role == .assistant,
              let attributed = try? AttributedString(markdown: message.content) else {
            return Text(message.content)
        }
        return Text(attributed)
    }

    /// Renders input area and send action.
    private var composerView: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Type a message", text: $messageInput, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitMessage()
                }

            Button("Send") {
                submitMessage()
            }
            .buttonStyle(.borderedProminent)
            .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatService.isResponding)
        }
    }

    /// Renders optional free-form context and selected PDF labels.
    private var contextBoxView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: chatService.isAnalyzingContext ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                    .foregroundColor(chatService.isAnalyzingContext ? .accentColor : .secondary)
                    .symbolEffect(.rotate.byLayer, isActive: chatService.isAnalyzingContext)
                Text("Context Sources")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    contextSources.append(ContextSource(kind: .url(text: "")))
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                Button("Add PDF") {
                    showFileImporter = true
                }
                .buttonStyle(.bordered)
            }

            ForEach(Array(contextSources.enumerated()), id: \.element.id) { index, source in
                contextRow(source: source, at: index)
            }

            if chatService.isAnalyzingContext {
                HStack(spacing: 8) {
                    ProgressView(value: chatService.contextAnalysisProgress)
                        .controlSize(.small)
                    Text("Analyzing sources…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Renders a single editable source row.
    private func contextRow(source: ContextSource, at index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: source.kindSymbol)
                .foregroundColor(source.kindColor)
            switch source.kind {
            case .url:
                TextField(
                    index == 0 ? "Paste URL or drop PDF here" : "Paste URL",
                    text: Binding(
                        get: {
                            guard case .url(let text) = contextSources[index].kind else { return "" }
                            return text
                        },
                        set: { newValue in
                            contextSources[index].kind = .url(text: newValue)
                            scheduleContextPreanalysis()
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            case .pdf:
                if case .pdf(let url) = source.kind {
                    Text(url?.lastPathComponent ?? "PDF")
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            Button {
                contextSources.remove(at: index)
                if contextSources.isEmpty {
                    contextSources = [ContextSource(kind: .url(text: ""))]
                }
                scheduleContextPreanalysis()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(8)
        .onDrop(of: [.pdf, .fileURL], isTargeted: nil) { providers in
            handlePDFDrop(providers, rowIndex: index)
        }
    }

    /// Validates and dispatches the current text input to the chat service.
    private func submitMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = trimmed
        messageInput = ""
        let contextInput = contextSources
            .compactMap { source -> String? in
                guard case .url(let text) = source.kind else { return nil }
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedText.isEmpty ? nil : trimmedText
            }
            .joined(separator: "\n")
        let selectedPDFs = contextSources.compactMap { source -> URL? in
            guard case .pdf(let url) = source.kind else { return nil }
            return url
        }

        Task {
            await chatService.sendMessage(message, contextInput: contextInput, pdfURLs: selectedPDFs)
        }
    }

    /// Handles dropped file providers and keeps PDF URLs only.
    private func handlePDFDrop(_ providers: [NSItemProvider], rowIndex: Int? = nil) -> Bool {
        debugDrop("Received drop with \(providers.count) providers at rowIndex=\(String(describing: rowIndex))")
        for (index, provider) in providers.enumerated() {
            debugDrop("Provider[\(index)] registeredTypeIdentifiers=\(provider.registeredTypeIdentifiers)")
        }
        let pdfProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        debugDrop("Filtered \(pdfProviders.count) candidate PDF providers")
        guard !pdfProviders.isEmpty else {
            debugDrop("Drop ignored: no provider conforms to public.pdf or public.file-url")
            return false
        }

        for (index, provider) in pdfProviders.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                debugDrop("Provider[\(index)] loading file representation for public.pdf")
                provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                    if let error {
                        debugDrop("Provider[\(index)] loadFileRepresentation error: \(error.localizedDescription)")
                    }
                    guard let url else {
                        debugDrop("Provider[\(index)] loadFileRepresentation returned nil URL")
                        return
                    }
                    debugDrop("Provider[\(index)] loadFileRepresentation url=\(url.path)")
                    guard let persistentURL = persistDroppedPDF(url) else {
                        debugDrop("Provider[\(index)] failed to persist dropped PDF at \(url.path)")
                        return
                    }
                    debugDrop("Provider[\(index)] persisted dropped PDF at \(persistentURL.path)")
                    Task { @MainActor in
                        insertPDFSource(persistentURL, at: rowIndex)
                    }
                }
                continue
            }

            debugDrop("Provider[\(index)] loading item for public.file-url")
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    debugDrop("Provider[\(index)] loadItem error: \(error.localizedDescription)")
                }
                debugDrop("Provider[\(index)] loadItem returned itemType=\(item.map { String(describing: type(of: $0)) } ?? "nil")")
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
                      fileURL.pathExtension.lowercased() == "pdf",
                      let persistentURL = persistDroppedPDF(fileURL) else {
                    debugDrop("Provider[\(index)] rejected dropped item; resolvedURL=\(fileURL?.path ?? "nil"), ext=\(fileURL?.pathExtension ?? "nil")")
                    return
                }
                debugDrop("Provider[\(index)] persisted file-url dropped PDF at \(persistentURL.path)")

                Task { @MainActor in
                    insertPDFSource(persistentURL, at: rowIndex)
                }
            }
        }

        return true
    }

    /// Copies dropped PDF to a stable temporary location so it remains readable for later context analysis.
    private func persistDroppedPDF(_ sourceURL: URL) -> URL? {
        let fileManager = FileManager.default
        let destinationDirectory = fileManager.temporaryDirectory.appendingPathComponent("PrivducaiDroppedPDFs", isDirectory: true)
        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let safeBaseName = baseName.isEmpty ? "dropped" : baseName
            let destinationURL = destinationDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(safeBaseName)")
                .appendingPathExtension("pdf")
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            debugDrop("Copied dropped PDF from \(sourceURL.path) to \(destinationURL.path)")
            return destinationURL
        } catch {
            debugDrop("Failed to persist dropped PDF from \(sourceURL.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Adds incoming shared URLs/PDFs to context rows once.
    private func mergeSharedInputsIfNeeded() {
        if !sharedURLs.isEmpty {
            for url in sharedURLs where !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contextSources.append(ContextSource(kind: .url(text: url)))
            }
            sharedURLs.removeAll()
        }
        if !sharedPDFs.isEmpty {
            appendPDFSources(sharedPDFs)
            sharedPDFs.removeAll()
        }
        normalizeContextSources()
        scheduleContextPreanalysis()
    }

    /// Inserts a PDF source while keeping URL placeholder behavior.
    private func insertPDFSource(_ url: URL, at rowIndex: Int?) {
        guard url.pathExtension.lowercased() == "pdf" else {
            debugDrop("Ignoring non-PDF URL during insert: \(url.path)")
            return
        }
        guard !contextSources.contains(where: { source in
            if case .pdf(let existingURL) = source.kind {
                return existingURL == url
            }
            return false
        }) else {
            debugDrop("Ignoring duplicate PDF context URL: \(url.path)")
            return
        }

        if let rowIndex, contextSources.indices.contains(rowIndex) {
            contextSources[rowIndex].kind = .pdf(url: url)
            debugDrop("Inserted dropped PDF into existing context row \(rowIndex): \(url.lastPathComponent)")
        } else {
            contextSources.append(ContextSource(kind: .pdf(url: url)))
            debugDrop("Appended dropped PDF as new context row: \(url.lastPathComponent)")
        }
        normalizeContextSources()
        scheduleContextPreanalysis()
    }

    private func debugDrop(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ChatView][PDFDrop] \(message())")
        #endif
    }

    /// Appends multiple PDFs.
    private func appendPDFSources(_ urls: [URL]) {
        for url in urls {
            insertPDFSource(url, at: nil)
        }
    }

    /// Ensures there is always one empty URL row available.
    private func normalizeContextSources() {
        let hasEmptyURLRow = contextSources.contains { source in
            if case .url(let text) = source.kind {
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
        if !hasEmptyURLRow {
            contextSources.append(ContextSource(kind: .url(text: "")))
        }
    }

    /// Triggers background context analysis shortly after edits.
    private func scheduleContextPreanalysis() {
        preanalysisTask?.cancel()
        let contextInput = contextSources
            .compactMap { source -> String? in
                guard case .url(let text) = source.kind else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
        let selectedPDFs = contextSources.compactMap { source -> URL? in
            guard case .pdf(let url) = source.kind else { return nil }
            return url
        }
        preanalysisTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await chatService.preAnalyzeContext(contextInput: contextInput, pdfURLs: selectedPDFs)
        }
    }
}

private struct ContextSource: Identifiable {
    enum Kind {
        case url(text: String)
        case pdf(url: URL?)
    }

    let id = UUID()
    var kind: Kind

    var kindSymbol: String {
        switch kind {
        case .url: return "link"
        case .pdf: return "doc.richtext"
        }
    }

    var kindColor: Color {
        switch kind {
        case .url: return .blue
        case .pdf: return .red
        }
    }
}
