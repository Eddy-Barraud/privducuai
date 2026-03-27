//
//  ChatService.swift
//  Privducai
//
//  Created by Eddy Barraud on 27/03/2026.
//

import Foundation
import Combine
import FoundationModels
import PDFKit

/// Service layer that orchestrates retrieval-augmented chat generation.
@MainActor
final class ChatService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isResponding = false
    @Published var errorMessage: String?
    @Published var isAnalyzingContext = false
    @Published var contextAnalysisProgress = 0.0

    private let webScraper = WebScrapingService()
    private let ragChunker = RAGChunker()
    private let ragContextService = RAGContextService()

    // Keep web retrieval bounded to control latency and context size.
    private static let maxWebContextURLs = 8
    private static let maxWebScrapeCharacters = 8000
    // Chunk sizes tuned to preserve locality while allowing many chunks in a 4096-token budget.
    private static let webChunkMaxTokens = 240
    private static let webChunkOverlapTokens = 40
    private static let pdfChunkMaxTokens = 220
    private static let pdfChunkOverlapTokens = 30
    // Keep recent turns only, to leave room for retrieved context.
    private static let historyMessageLimit = 6
    // Response budget for chat generation while preserving room for retrieved context.
    private static let chatResponseTokens = 700
    private var preAnalyzedContextKey: String?
    private var preAnalyzedChunks: [RAGChunk] = []

    /// Sends a user message and appends the assistant response.
    func sendMessage(_ message: String, contextInput: String, pdfURLs: [URL]) async {
        messages.append(ChatMessage(role: .user, content: message))
        errorMessage = nil

        isResponding = true
        defer { isResponding = false }

        let contextKey = makeContextKey(contextInput: contextInput, pdfURLs: pdfURLs)
        let chunks: [RAGChunk]
        if contextKey == preAnalyzedContextKey {
            chunks = preAnalyzedChunks
        } else {
            chunks = await collectChunks(contextInput: contextInput, pdfURLs: pdfURLs)
            preAnalyzedContextKey = contextKey
            preAnalyzedChunks = chunks
        }
        let selected = await ragContextService.selectContext(
            chunks: chunks,
            query: message,
            maxResponseTokens: Self.chatResponseTokens
        )

        do {
            let instructions = """
            You are a helpful chat assistant. Answer the user clearly and accurately.
            Use retrieved context when relevant and mention uncertainty when context is insufficient.
            """
            let session = LanguageModelSession(instructions: instructions)
            let prompt = buildPrompt(for: message, selectedContext: selected.selectedContext)
            let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: Self.chatResponseTokens)
            let response = try await session.respond(to: prompt, options: options)
            let content = String(describing: response.content)
                + RAGCitationFormatter.citationBlock(from: selected.topChunks)
            messages.append(ChatMessage(role: .assistant, content: content))
        } catch {
            let fallback = "I couldn't generate a response with the foundation model right now. Please try again."
            messages.append(ChatMessage(role: .assistant, content: fallback))
            errorMessage = error.localizedDescription
        }
    }

    /// Pre-analyzes context in the background so send-time latency remains low.
    func preAnalyzeContext(contextInput: String, pdfURLs: [URL]) async {
        let contextKey = makeContextKey(contextInput: contextInput, pdfURLs: pdfURLs)
        if contextKey.isEmpty {
            preAnalyzedContextKey = nil
            preAnalyzedChunks = []
            isAnalyzingContext = false
            contextAnalysisProgress = 0
            return
        }
        if contextKey == preAnalyzedContextKey { return }

        isAnalyzingContext = true
        contextAnalysisProgress = 0
        let chunks = await collectChunks(contextInput: contextInput, pdfURLs: pdfURLs, reportProgress: true)
        preAnalyzedContextKey = contextKey
        preAnalyzedChunks = chunks
    }

    /// Collects web and PDF chunks from provided context.
    private func collectChunks(contextInput: String, pdfURLs: [URL], reportProgress: Bool = false) async -> [RAGChunk] {
        var chunks: [RAGChunk] = []
        if reportProgress {
            isAnalyzingContext = true
            contextAnalysisProgress = 0
        }
        defer {
            if reportProgress {
                contextAnalysisProgress = 1
                isAnalyzingContext = false
            }
        }

        let urls = extractURLs(from: contextInput)
        let uniquePDFs = Array(Set(pdfURLs))
        let totalWorkItems = max(urls.count + uniquePDFs.count, 1)
        var completedWorkItems = 0

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
                    overlapTokens: Self.webChunkOverlapTokens,
                    url: url
                )
                chunks.append(contentsOf: chunked)
                completedWorkItems += 1
                if reportProgress {
                    contextAnalysisProgress = Double(completedWorkItems) / Double(totalWorkItems)
                }
            }
        }

        for pdfURL in uniquePDFs {
            let pageTexts = extractPDFPageTexts(from: pdfURL)
            for (pageIndex, pageText) in pageTexts.enumerated() {
                let source = "PDF: \(pdfURL.lastPathComponent) page \(pageIndex + 1)"
                let chunked = ragChunker.chunk(
                    text: pageText,
                    source: source,
                    maxChunkTokens: Self.pdfChunkMaxTokens,
                    overlapTokens: Self.pdfChunkOverlapTokens,
                    pdfPage: pageIndex + 1
                )
                chunks.append(contentsOf: chunked)
            }
            completedWorkItems += 1
            if reportProgress {
                contextAnalysisProgress = Double(completedWorkItems) / Double(totalWorkItems)
            }
        }

        return chunks
    }

    /// Returns a stable key used to reuse pre-analyzed context.
    private func makeContextKey(contextInput: String, pdfURLs: [URL]) -> String {
        let normalizedContext = contextInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPDFPaths = Array(Set(pdfURLs.map(\.path))).sorted().joined(separator: "|")
        if normalizedContext.isEmpty && normalizedPDFPaths.isEmpty {
            return ""
        }
        return "\(normalizedContext)||\(normalizedPDFPaths)"
    }

    /// Extracts unique HTTP(S) URLs from free-form text.
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

    /// Extracts non-empty text from every page of a PDF file URL.
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

    /// Builds the model prompt from recent history and retrieved context.
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

/// Represents a chat turn in the conversation.
struct ChatMessage: Identifiable {
    /// Distinguishes user and assistant messages.
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let content: String
}
