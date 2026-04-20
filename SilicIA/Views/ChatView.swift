//
//  ChatView.swift
//  SilicIA
//
//  Created by Eddy Barraud on 27/03/2026.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LaTeXSwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Chat UI that sends prompts and contextual documents to `ChatService`.
struct ChatView: View {
    @Binding var sharedURLs: [String]
    @Binding var sharedPDFs: [URL]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    let chatService: ChatService

    @State private var messageInput = ""
    @State private var showFileImporter = false
    @State private var contextSources: [ContextSource] = [ContextSource(kind: .url(text: ""))]
    @State private var preanalysisTask: Task<Void, Never>?
    @State private var settings = AppSettings.load()
    @State private var showSettings = false
    @State private var showHistory = false
    @FocusState private var isInputFieldFocused: Bool
    @State private var copiedMessageID: ChatMessage.ID?
    @State private var isWebSearchEnabled = false
    @StateObject private var speechRecognitionService = SpeechRecognitionService()
    @State private var activeVoiceInputTarget: VoiceInputTarget?

    private var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }

    private var textBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.textBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    private var estimatedMaxOutputCharacters: Int {
        TokenBudgeting.estimatedOutputCharacters(forTokens: settings.maxResponseTokens)
    }

    private var estimatedMaxOutputSentences: Int {
        TokenBudgeting.estimatedOutputSentences(forTokens: settings.maxResponseTokens)
    }

    private var maxAllowedContextTokensForCurrentResponse: Int {
        AppSettings.maxAllowedContextTokens(forResponseTokens: settings.maxResponseTokens)
    }

    private var effectiveContextTokens: Int {
        min(settings.maxContextTokens, maxAllowedContextTokensForCurrentResponse)
    }

    private var estimatedMaxContextWords: Int {
        TokenBudgeting.estimatedContextWords(forTokens: effectiveContextTokens)
    }

    private var speechLocale: Locale {
        settings.language == .french ? Locale(identifier: "fr-FR") : Locale(identifier: "en-US")
    }

    /// Renders chat transcript, composer, and context inputs.
    var body: some View {
        if showHistory {
            ConversationsListView(
                onLoadConversation: { conversation in
                    chatService.loadConversation(id: conversation.id)
                    showHistory = false
                },
                onDismiss: {
                    showHistory = false
                }
            )
        } else {
            VStack(spacing: 12) {
                chatHeaderView

                if showSettings {
                    chatSettingsPanel
                }

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
            #if canImport(UIKit)
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissKeyboard()
                }
            )
            #endif
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
                settings = AppSettings.load()
                chatService.modelContext = modelContext
                mergeSharedInputsIfNeeded()
            }
            .onDisappear {
                speechRecognitionService.stop()
                activeVoiceInputTarget = nil
            }
            .onChange(of: settings) {
                settings.save()
            }
            .onChange(of: sharedURLs) {
                mergeSharedInputsIfNeeded()
            }
            .onChange(of: sharedPDFs) {
                mergeSharedInputsIfNeeded()
            }
        }
    }

    /// Renders top-level chat actions.
    private var chatHeaderView: some View {
        HStack {
            Button(action: { startOver() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.circlepath")
                    Text(settings.language == .french ? "Nouveau" : "Start Over")
                        .fontWeight(.medium)
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(action: { showHistory = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(settings.language == .french ? "Historique" : "History")
                        .fontWeight(.medium)
                }
            }
            .buttonStyle(.bordered)

            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 2)
        .textSelection(.enabled)
    }

    /// Renders chat-specific tuning controls.
    private var chatSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(settings.language == .french ? "Paramètres de chat" : "Chat Settings")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Température de l'IA" : "AI Temperature")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", settings.temperature))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.temperature, in: AppSettings.temperatureRange, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Tokens de réponse max" : "Max Response Tokens")
                        .font(.subheadline)
                    Spacer()
                    Text("\(settings.maxResponseTokens)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(settings.maxResponseTokens) },
                    set: {
                        settings.maxResponseTokens = Int($0)
                        settings.maxContextTokens = min(
                            settings.maxContextTokens,
                            AppSettings.maxAllowedContextTokens(forResponseTokens: settings.maxResponseTokens)
                        )
                    }
                ), in: Double(AppSettings.maxResponseTokensRange.lowerBound)...Double(AppSettings.maxResponseTokensRange.upperBound), step: 100)

                Text(
                    settings.language == .french
                    ? "Sortie max estimée : ~\(estimatedMaxOutputCharacters) caractères (~\(estimatedMaxOutputSentences) phrases)"
                    : "Estimated max output: ~\(estimatedMaxOutputCharacters) characters (~\(estimatedMaxOutputSentences) sentences)"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Tokens de contexte max" : "Max Context Tokens")
                        .font(.subheadline)
                    Spacer()
                    Text("\(effectiveContextTokens)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(effectiveContextTokens) },
                    set: { settings.maxContextTokens = Int($0) }
                ), in: Double(AppSettings.maxContextTokensRange.lowerBound)...Double(maxAllowedContextTokensForCurrentResponse), step: 50)

                Text(
                    settings.language == .french
                    ? "Contexte estimé : ~\(estimatedMaxContextWords) mots"
                    : "Estimated context: ~\(estimatedMaxContextWords) words"
                )
                .font(.caption)
                .foregroundColor(.secondary)

                if effectiveContextTokens < settings.maxContextTokens {
                    Text(
                        settings.language == .french
                        ? "Le contexte est plafonné automatiquement avec la limite de réponse actuelle."
                        : "Context is automatically capped by the current response-token limit."
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(controlBackgroundColor)
        .cornerRadius(12)
    }

    /// Renders message history and in-progress state.
    private var messagesView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if chatService.messages.isEmpty {
                    Text(settings.language == .french ? "Commencez une conversation de chat avec le modèle." : "Start a chat conversation with the foundation model.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(chatService.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(message.role == .user ? settings.language == .french ? "Vous" : "You" : settings.language == .french ? "Assistant" : "Assistant")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            if message.role == .assistant {
                                Button {
                                    copyPlainTextToClipboard(message.content)
                                    copiedMessageID = message.id
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.2))
                                        if copiedMessageID == message.id {
                                            copiedMessageID = nil
                                        }
                                    }
                                } label: {
                                    Image(systemName: copiedMessageID == message.id ? "checkmark.circle.fill" : "doc.on.doc")
                                        .foregroundColor(copiedMessageID == message.id ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help(settings.language == .french ? "Copier" : "Copy")
                            }
                        }
                        renderedMessageContent(message)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(
                        message.role == .user
                        ? Color.accentColor.opacity(0.15)
                        : controlBackgroundColor
                    )
                    .cornerRadius(10)
                    .frame(
                        maxWidth: .infinity,
                        alignment: message.role == .assistant ? .leading : .trailing
                    )
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
        .background(textBackgroundColor)
        .cornerRadius(10)
    }

    /// Renders assistant replies with LaTeX-aware text and keeps plaintext for user turns.
    @ViewBuilder
    private func renderedMessageContent(_ message: ChatMessage) -> some View {
        if message.role == .assistant {
            VStack(alignment: .leading, spacing: 8) {
                LaTeX(ModelOutputLaTeXSanitizer.sanitize(message.content))
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .black)

                if let citations = message.citations,
                   !citations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()

                    if let attributedCitations = try? AttributedString(markdown: citations) {
                        Text(attributedCitations)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .tint(.accentColor)
                    } else {
                        Text(citations)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } else {
            Text(message.content)
        }
    }

    /// Renders input area and send action.
    private var composerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Type a message", text: $messageInput, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFieldFocused)
                    #if canImport(UIKit)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    #endif
                    .onSubmit {
                        submitMessage()
                    }

                Button {
                    toggleVoiceRecognition(for: .message)
                } label: {
                    Image(systemName: activeVoiceInputTarget == .message && speechRecognitionService.isListening ? "mic.fill" : "mic")
                        .foregroundColor(activeVoiceInputTarget == .message && speechRecognitionService.isListening ? .red : .secondary)
                }
                .buttonStyle(.plain)

                Button("Send") {
                    submitMessage()
                }
                .buttonStyle(.borderedProminent)
                .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatService.isResponding)
            }

            if let speechError = speechRecognitionService.errorMessage,
               !speechError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(speechError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
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
                Button {
                    isWebSearchEnabled.toggle()
                } label: {
                    Label("Web", systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .tint(isWebSearchEnabled ? .accentColor : .secondary)
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
                .focused($isInputFieldFocused)

                Button {
                    toggleVoiceRecognition(for: .context(source.id))
                } label: {
                    Image(systemName: activeVoiceInputTarget == .context(source.id) && speechRecognitionService.isListening ? "mic.fill" : "mic")
                        .foregroundColor(activeVoiceInputTarget == .context(source.id) && speechRecognitionService.isListening ? .red : .secondary)
                }
                .buttonStyle(.plain)
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
        .background(textBackgroundColor)
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
        #if canImport(UIKit)
        dismissKeyboard()
        #endif

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
            await chatService.sendMessage(
                message,
                contextInput: contextInput,
                pdfURLs: selectedPDFs,
                includeWebSearch: isWebSearchEnabled,
                language: settings.language,
                temperature: settings.temperature,
                maxResponseTokens: settings.maxResponseTokens,
                maxContextTokens: settings.maxContextTokens
            )
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
                    let preferredName = provider.suggestedName
                    guard let persistentURL = persistDroppedPDF(url, preferredFileName: preferredName) else {
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
    private func persistDroppedPDF(_ sourceURL: URL, preferredFileName: String? = nil) -> URL? {
        let persistentURL = DroppedPDFStore.persist(sourceURL, preferredFileName: preferredFileName)
        if let persistentURL {
            debugDrop("Copied dropped PDF from \(sourceURL.path) to \(persistentURL.path)")
        } else {
            debugDrop("Failed to persist dropped PDF from \(sourceURL.path)")
        }
        return persistentURL
    }

    /// Adds incoming shared URLs/PDFs to context rows once.
    private func mergeSharedInputsIfNeeded() {
        let incomingURLs = sharedURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let incomingPDFs = sharedPDFs
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .compactMap { sourceURL in
                persistDroppedPDF(sourceURL, preferredFileName: sourceURL.lastPathComponent) ?? sourceURL
            }
        guard !incomingURLs.isEmpty || !incomingPDFs.isEmpty else { return }

        startNewConversationFromSharedInputs(urls: incomingURLs, pdfs: incomingPDFs)
        sharedURLs.removeAll()
        sharedPDFs.removeAll()
        scheduleContextPreanalysis()
    }

    private func startNewConversationFromSharedInputs(urls: [String], pdfs: [URL]) {
        preanalysisTask?.cancel()
        messageInput = ""
        isWebSearchEnabled = false
        chatService.resetConversation()

        var newSources: [ContextSource] = urls.map { ContextSource(kind: .url(text: $0)) }
        newSources.append(contentsOf: pdfs.map { ContextSource(kind: .pdf(url: $0)) })
        contextSources = newSources
        normalizeContextSources()
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

    private func copyPlainTextToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    #if canImport(UIKit)
    private func dismissKeyboard() {
        isInputFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    #endif

    /// Appends multiple PDFs.
    private func appendPDFSources(_ urls: [URL]) {
        for url in urls {
            let persisted = persistDroppedPDF(url, preferredFileName: url.lastPathComponent) ?? url
            insertPDFSource(persisted, at: nil)
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
            await chatService.preAnalyzeContext(
                contextInput: contextInput,
                pdfURLs: selectedPDFs,
                includeWebSearch: isWebSearchEnabled,
                maxContextTokens: settings.maxContextTokens,
                maxResponseTokens: settings.maxResponseTokens
            )
        }
    }

    /// Resets transcript and local context inputs to start a new conversation.
    private func startOver() {
        preanalysisTask?.cancel()
        speechRecognitionService.stop()
        activeVoiceInputTarget = nil
        messageInput = ""
        contextSources = [ContextSource(kind: .url(text: ""))]
        isWebSearchEnabled = false
        sharedURLs.removeAll()
        sharedPDFs.removeAll()
        chatService.resetConversation()
        _ = DroppedPDFStore.clearAll()
    }

    private func toggleVoiceRecognition(for target: VoiceInputTarget) {
        if speechRecognitionService.isListening, activeVoiceInputTarget == target {
            speechRecognitionService.stop()
            activeVoiceInputTarget = nil
            return
        }

        speechRecognitionService.stop()
        activeVoiceInputTarget = target

        speechRecognitionService.start(
            initialText: text(for: target),
            locale: speechLocale,
            onTextUpdate: { recognizedText in
                applyRecognizedText(recognizedText, to: target)
            },
            onStop: {
                activeVoiceInputTarget = nil
            }
        )
    }

    private func text(for target: VoiceInputTarget) -> String {
        switch target {
        case .message:
            return messageInput
        case .context(let sourceID):
            guard let source = contextSources.first(where: { $0.id == sourceID }),
                  case .url(let text) = source.kind else {
                return ""
            }
            return text
        }
    }

    private func applyRecognizedText(_ text: String, to target: VoiceInputTarget) {
        switch target {
        case .message:
            messageInput = text
        case .context(let sourceID):
            guard let index = contextSources.firstIndex(where: { $0.id == sourceID }) else { return }
            contextSources[index].kind = .url(text: text)
            scheduleContextPreanalysis()
        }
    }
}

private enum ModelOutputLaTeXSanitizer {
    static func sanitize(_ input: String) -> String {
        var sanitized = input
        sanitized = replacingRegex(
            in: sanitized,
            pattern: #"(?<!\s)(\\[A-Za-z]+)"#,
            with: " $1"
        )
        sanitized = replacingRegex(
            in: sanitized,
            pattern: #"(\\[A-Za-z]+)(?=[0-9A-Za-z])"#,
            with: "$1 "
        )
        sanitized = replacingDigitPowers(in: sanitized)
        sanitized = closeUnbalancedMathDelimiters(in: sanitized)
        return sanitized
    }

    private static func replacingDigitPowers(in text: String) -> String {
        var output = text
        output = replacingDigitPowerMatches(in: output, pattern: #"(?<!\\mathrm\{)(\d+)\^\{([^{}]+)\}"#)
        output = replacingDigitPowerMatches(in: output, pattern: #"(?<!\\mathrm\{)(\d+)\^(-?\d+)"#)
        return output
    }

    private static func replacingDigitPowerMatches(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let wholeRange = Range(match.range(at: 0), in: output),
                  let baseRange = Range(match.range(at: 1), in: output),
                  let exponentRange = Range(match.range(at: 2), in: output) else {
                continue
            }

            let base = String(output[baseRange])
            let exponent = String(output[exponentRange])
            output.replaceSubrange(wholeRange, with: "\\mathrm{\(base)}^\\mathrm{\(exponent)}")
        }
        return output
    }

    private static func closeUnbalancedMathDelimiters(in text: String) -> String {
        var singleDollarCount = 0
        var doubleDollarCount = 0
        var openParenCount = 0
        var closeParenCount = 0
        var openBracketCount = 0
        var closeBracketCount = 0

        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let current = characters[index]

            if current == "\\" {
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if next == "(" {
                        openParenCount += 1
                        index += 2
                        continue
                    }
                    if next == ")" {
                        closeParenCount += 1
                        index += 2
                        continue
                    }
                    if next == "[" {
                        openBracketCount += 1
                        index += 2
                        continue
                    }
                    if next == "]" {
                        closeBracketCount += 1
                        index += 2
                        continue
                    }
                    if next == "$" {
                        index += 2
                        continue
                    }
                }
                index += 1
                continue
            }

            if current == "$" {
                if index + 1 < characters.count, characters[index + 1] == "$" {
                    doubleDollarCount += 1
                    index += 2
                } else {
                    singleDollarCount += 1
                    index += 1
                }
                continue
            }

            index += 1
        }

        var output = text
        if doubleDollarCount % 2 != 0 {
            output += "$$"
        }
        if singleDollarCount % 2 != 0 {
            output += "$"
        }
        if openParenCount > closeParenCount {
            output += String(repeating: "\\)", count: openParenCount - closeParenCount)
        }
        if openBracketCount > closeBracketCount {
            output += String(repeating: "\\]", count: openBracketCount - closeBracketCount)
        }

        return output
    }

    private static func replacingRegex(in text: String, pattern: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

private enum VoiceInputTarget: Equatable {
    case message
    case context(UUID)
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
