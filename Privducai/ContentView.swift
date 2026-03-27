//
//  ContentView.swift
//  Privducai
//
//  Created by Eddy Barraud on 23/03/2026.
//

import SwiftUI
import Foundation
import FoundationModels
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    private enum AppTab: String, CaseIterable, Identifiable {
        case searchAssist = "Search Assist"
        case chat = "Chat"

        var id: String { rawValue }
    }

    @State private var selectedTab: AppTab = .searchAssist

    var body: some View {
        VStack(spacing: 0) {
            Picker("Application", selection: $selectedTab) {
                Text(AppTab.searchAssist.rawValue).tag(AppTab.searchAssist)
                Text(AppTab.chat.rawValue).tag(AppTab.chat)
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider()

            Group {
                switch selectedTab {
                case .searchAssist:
                    SearchView()
                case .chat:
                    ChatView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ChatView: View {
    @StateObject private var chatService = ChatService()

    @State private var messageInput = ""
    @State private var contextInput = ""
    @State private var selectedPDFs: [URL] = []
    @State private var isDropTargeted = false
    @State private var showFileImporter = false

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

            dropAreaView
        }
        .padding()
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            selectedPDFs.append(contentsOf: urls)
            selectedPDFs = deduplicateAndSortPDFs(selectedPDFs)
        }
    }

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
                            Text(message.content)
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

    private var contextBoxView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context")
                .font(.subheadline)
                .fontWeight(.semibold)

            TextEditor(text: $contextInput)
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button("Add PDF") {
                    showFileImporter = true
                }
                .buttonStyle(.bordered)

                if !selectedPDFs.isEmpty {
                    Text(selectedPDFs.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var dropAreaView: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 1.5, dash: [6])
            )
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .frame(height: 56)
            .overlay(
                Text("Drop PDF here to add context")
                    .font(.caption)
                    .foregroundColor(.secondary)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handlePDFDrop)
    }

    private func submitMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = trimmed
        messageInput = ""

        Task {
            await chatService.sendMessage(message, contextInput: contextInput, pdfURLs: selectedPDFs)
        }
    }

    private func handlePDFDrop(_ providers: [NSItemProvider]) -> Bool {
        let pdfProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !pdfProviders.isEmpty else { return false }

        for provider in pdfProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let fileURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?,
                      fileURL.pathExtension.lowercased() == "pdf" else {
                    return
                }

                Task { @MainActor in
                    selectedPDFs.append(fileURL)
                    selectedPDFs = deduplicateAndSortPDFs(selectedPDFs)
                }
            }
        }

        return true
    }

    private func deduplicateAndSortPDFs(_ urls: [URL]) -> [URL] {
        Array(Set(urls)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }
}

@MainActor
private final class ChatService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isResponding = false
    @Published var errorMessage: String?

    private let webScraper = WebScrapingService()
    private let ragChunker = RAGChunker()

    // Apple Foundation Models practical context window budget.
    // Context is always selected/truncated to fit this limit before generation.
    private static let contextWindowLimit = 4096
    // Conservative estimate to keep selected text under token limits across mixed languages.
    private static let avgCharsPerToken = 3
    // Keep web retrieval bounded to control latency and context size.
    private static let maxWebContextURLs = 8
    private static let maxWebScrapeCharacters = 8000
    // Chunk sizes tuned to preserve locality while allowing many chunks in a 4096-token budget.
    private static let webChunkMaxTokens = 240
    private static let webChunkOverlapTokens = 40
    private static let pdfChunkMaxTokens = 220
    private static let pdfChunkOverlapTokens = 30
    // Token reservation for instructions/template/response before retrieved context allocation.
    private static let instructionTokens = 120
    private static let promptOverheadTokens = 120
    private static let minContextTokens = 300
    // Safety margin for tokenization variance.
    private static let contextUtilizationFactor = 0.8
    // Keep recent turns only, to leave room for retrieved context.
    private static let historyMessageLimit = 6
    // Guarantee minimum fallback context even under very small calculated budgets.
    private static let minimumFallbackContextCharacters = 200
    // Slightly prefer richer chunks while still primarily ranking by lexical relevance.
    private static let longChunkCharacterThreshold = 300
    private static let longChunkBonusScore = 0.2

    func sendMessage(_ message: String, contextInput: String, pdfURLs: [URL]) async {
        messages.append(ChatMessage(role: .user, content: message))
        errorMessage = nil

        isResponding = true
        defer { isResponding = false }

        let chunks = await collectChunks(contextInput: contextInput, pdfURLs: pdfURLs)
        let selectedContext = selectContext(chunks: chunks, query: message, maxResponseTokens: 700)

        do {
            let instructions = """
            You are a helpful chat assistant. Answer the user clearly and accurately.
            Use retrieved context when relevant and mention uncertainty when context is insufficient.
            """
            let session = LanguageModelSession(instructions: instructions)
            let prompt = buildPrompt(for: message, selectedContext: selectedContext)
            let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 700)
            let response = try await session.respond(to: prompt, options: options)
            messages.append(ChatMessage(role: .assistant, content: String(describing: response.content)))
        } catch {
            let fallback = "I couldn't generate a response with the foundation model right now. Please try again."
            messages.append(ChatMessage(role: .assistant, content: fallback))
            errorMessage = error.localizedDescription
        }
    }

    private func collectChunks(contextInput: String, pdfURLs: [URL]) async -> [RAGChunk] {
        var chunks: [RAGChunk] = []

        let urls = extractURLs(from: contextInput)
        if !urls.isEmpty {
            let scraped = await webScraper.scrapeMultiplePages(
                urls: urls,
                limit: min(urls.count, Self.maxWebContextURLs),
                maxCharacters: Self.maxWebScrapeCharacters
            )
            for url in urls {
                guard let text = scraped[url] else { continue }
                let chunked = ragChunker.chunk(
                    text: text,
                    source: "Web: \(url)",
                    maxChunkTokens: Self.webChunkMaxTokens,
                    overlapTokens: Self.webChunkOverlapTokens
                )
                chunks.append(contentsOf: chunked)
            }
        }

        for pdfURL in Array(Set(pdfURLs)) {
            let pageTexts = extractPDFPageTexts(from: pdfURL)
            for (pageIndex, pageText) in pageTexts.enumerated() {
                let source = "PDF: \(pdfURL.lastPathComponent) page \(pageIndex + 1)"
                let chunked = ragChunker.chunk(
                    text: pageText,
                    source: source,
                    maxChunkTokens: Self.pdfChunkMaxTokens,
                    overlapTokens: Self.pdfChunkOverlapTokens
                )
                chunks.append(contentsOf: chunked)
            }
        }

        return chunks
    }

    private func extractURLs(from raw: String) -> [String] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let found = detector?.matches(in: raw, options: [], range: range) ?? []

        let urls = found.compactMap { match -> String? in
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }
            return url.absoluteString
        }

        return Array(Set(urls))
    }

    private func extractPDFPageTexts(from url: URL) -> [String] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: url) else { return [] }
        var pages: [String] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let pageString = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pageString.isEmpty else {
                continue
            }
            pages.append(pageString)
        }

        return pages
    }

    private func selectContext(chunks: [RAGChunk], query: String, maxResponseTokens: Int) -> String {
        guard !chunks.isEmpty else {
            return "No additional context provided."
        }

        let maxContextChars = calculateMaxContextCharacters(maxResponseTokens: maxResponseTokens)

        let ranked = chunks
            .map { chunk in
                (chunk, relevanceScore(text: chunk.text, query: query))
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.text.count > rhs.0.text.count
                }
                return lhs.1 > rhs.1
            }

        var selected: [String] = []
        var currentChars = 0

        for (chunk, _) in ranked {
            let entry = "Source: \(chunk.source)\n\(chunk.text)"
            if currentChars + entry.count > maxContextChars {
                continue
            }
            selected.append(entry)
            currentChars += entry.count
        }

        if selected.isEmpty, let first = ranked.first {
            let fallback = "Source: \(first.0.source)\n\(first.0.text)"
            return String(fallback.prefix(max(Self.minimumFallbackContextCharacters, maxContextChars)))
        }

        return selected.joined(separator: "\n\n---\n\n")
    }

    private func calculateMaxContextCharacters(maxResponseTokens: Int) -> Int {
        let effectiveResponseTokens = min(
            maxResponseTokens,
            Self.contextWindowLimit - Self.instructionTokens - Self.promptOverheadTokens - Self.minContextTokens
        )
        let reservedTokens = Self.instructionTokens + Self.promptOverheadTokens + effectiveResponseTokens
        let availableTokens = max(Self.contextWindowLimit - reservedTokens, 0)
        return Int(Double(availableTokens * Self.avgCharsPerToken) * Self.contextUtilizationFactor)
    }

    private func relevanceScore(text: String, query: String) -> Double {
        let queryWords = Set(
            query.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 }
        )
        guard !queryWords.isEmpty else { return 0 }

        let textWords = Set(
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        )
        var score = 0.0
        for word in queryWords where textWords.contains(word) {
            score += 1.0
        }

        if text.count > Self.longChunkCharacterThreshold {
            score += Self.longChunkBonusScore
        }

        return score
    }

    private func buildPrompt(for userMessage: String, selectedContext: String) -> String {
        let history = messages
            .suffix(Self.historyMessageLimit)
            .map { item in
                "\(item.role == .user ? "User" : "Assistant"): \(item.content)"
            }
            .joined(separator: "\n")

        return """
        Conversation:
        \(history)

        Retrieved Context:
        \(selectedContext)

        User question:
        \(userMessage)

        Answer in a concise and practical way.
        """
    }
}

private struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let content: String
}

private struct RAGChunk: Identifiable {
    let id = UUID()
    let source: String
    let text: String
}

private struct RAGChunker {
    private static let avgCharsPerToken = 3
    private static let whitespacePattern = "\\s+"
    // Keep chunks large enough to carry coherent information for retrieval.
    private static let minimumChunkCharacters = 200

    func chunk(text: String, source: String, maxChunkTokens: Int, overlapTokens: Int) -> [RAGChunk] {
        let cleanText = text
            .replacingOccurrences(of: Self.whitespacePattern, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanText.isEmpty else { return [] }

        let maxChunkChars = max(Self.minimumChunkCharacters, maxChunkTokens * Self.avgCharsPerToken)
        let overlapChars = min(maxChunkChars / 2, max(0, overlapTokens * Self.avgCharsPerToken))
        let stride = max(1, maxChunkChars - overlapChars)

        var chunks: [RAGChunk] = []
        var start = cleanText.startIndex

        while start < cleanText.endIndex {
            let end = cleanText.index(start, offsetBy: maxChunkChars, limitedBy: cleanText.endIndex) ?? cleanText.endIndex
            let piece = String(cleanText[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(RAGChunk(source: source, text: piece))
            }

            if end == cleanText.endIndex { break }
            start = cleanText.index(start, offsetBy: stride, limitedBy: cleanText.endIndex) ?? cleanText.endIndex
        }

        return chunks
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 700)
}
