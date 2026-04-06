//
//  ChatService.swift
//  SilicIA
//
//  Created by Eddy Barraud on 27/03/2026.
//

import Foundation
import Combine
import SwiftData
import FoundationModels
import PDFKit
import NaturalLanguage
import Vision
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Service layer that orchestrates retrieval-augmented chat generation.
@MainActor
final class ChatService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isResponding = false
    @Published var errorMessage: String?
    @Published var isAnalyzingContext = false
    @Published var contextAnalysisProgress = 0.0

    private let webScraper = WebScrapingService()
    private let webSearchService = DuckDuckGoService()
    private let ragChunker = RAGChunker()
    private let ragContextService = RAGContextService()

    // SwiftData persistence
    var modelContext: ModelContext?
    private var currentConversation: Conversation?
    private var pendingSaveTask: Task<Void, Never>?

    // Keep web retrieval bounded to control latency and context size.
    private static let maxWebContextURLs = 8
    // Chunk sizes tuned to preserve locality while allowing many chunks in a 4096-token budget.
    private static let webChunkMaxTokens = 240
    private static let webChunkOverlapTokens = 40
    private static let pdfChunkMaxTokens = 220
    private static let pdfChunkOverlapTokens = 30
    private static let minWebScrapingCharacters = 1500
    private static let maxWebScrapingCharacters = 12000
    private static let maxRecentMessagesForWebSearch = 4
    private static let maxWebSearchQueryLength = 500
    // Keep recent turns only, to leave room for retrieved context.
    private static let historyMessageLimit = 6
    private static let saveDebounceIntervalNanoseconds: UInt64 = 250_000_000
    private var preAnalyzedContextKey: String?
    private var preAnalyzedChunks: [RAGChunk] = []
    private var preAnalyzedMaxContextTokens: Int?

    /// Sends a user message and appends the assistant response.
    func sendMessage(
        _ message: String,
        contextInput: String,
        pdfURLs: [URL],
        includeWebSearch: Bool,
        language: ModelLanguage,
        temperature: Double,
        maxResponseTokens: Int,
        maxContextTokens: Int
    ) async {
        messages.append(ChatMessage(role: .user, content: message))
        persistMessage(role: "user", content: message, citations: nil)
        errorMessage = nil

        isResponding = true
        defer { isResponding = false }

        let contextKey = makeContextKey(
            contextInput: contextInput,
            pdfURLs: pdfURLs,
            includeWebSearch: includeWebSearch,
            searchQuerySeed: includeWebSearch ? message : ""
        )
        let hasRequestedContext = !contextKey.isEmpty
        let effectiveMaxOutputTokens = calculateEffectiveMaxOutputTokens(maxResponseTokens)
        let canUsePreAnalyzed = contextKey == preAnalyzedContextKey
            && maxContextTokens == preAnalyzedMaxContextTokens
            && (!hasRequestedContext || !preAnalyzedChunks.isEmpty)
        debugContext("sendMessage contextKeyEmpty=\(contextKey.isEmpty) pdfCount=\(pdfURLs.count) preAnalyzedKeyMatch=\(contextKey == preAnalyzedContextKey) preAnalyzedChunks=\(preAnalyzedChunks.count) canUsePreAnalyzed=\(canUsePreAnalyzed)")
        let chunks: [RAGChunk]
        if canUsePreAnalyzed {
            chunks = preAnalyzedChunks
        } else {
            chunks = await collectChunks(
                contextInput: contextInput,
                pdfURLs: pdfURLs,
                includeWebSearch: includeWebSearch,
                currentMessage: message,
                maxContextTokens: maxContextTokens
            )
            preAnalyzedContextKey = contextKey
            preAnalyzedChunks = chunks
            preAnalyzedMaxContextTokens = maxContextTokens
        }
        debugContext("sendMessage collected chunkCount=\(chunks.count)")
        let selected = await ragContextService.selectContext(
            chunks: chunks,
            query: message,
            maxOutputTokens: effectiveMaxOutputTokens,
            contextUtilizationFactor: RAGSelectionOptions.default.contextUtilizationFactor
        )
        let contextTokenCap = clampContextTokens(maxContextTokens)
        let maxPromptContextCharacters = TokenBudgeting.maxContextCharacters(
            maxOutputTokens: effectiveMaxOutputTokens,
            contextUtilizationFactor: 1.0
        )
        let effectiveContextTokenCap = min(
            contextTokenCap,
            TokenBudgeting.estimatedTokens(forApproxCharacters: maxPromptContextCharacters)
        )
        let contextWordEstimate = TokenBudgeting.estimatedContextWords(forTokens: effectiveContextTokenCap)
        let contextCharacterCap = min(
            TokenBudgeting.estimatedContextCharacters(forTokens: effectiveContextTokenCap),
            maxPromptContextCharacters
        )
        let cappedSelectedContext = String(selected.selectedContext.prefix(max(contextCharacterCap, 0)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wordLimitedSelectedContext = TokenBudgeting.truncateToApproxWordCount(
            selected.selectedContext,
            maxWords: contextWordEstimate
        )
        let finalSelectedContext = wordLimitedSelectedContext.count < cappedSelectedContext.count
            ? wordLimitedSelectedContext
            : cappedSelectedContext
        debugContext("sendMessage selectedContextChars=\(selected.selectedContext.count) cappedContextChars=\(finalSelectedContext.count) contextTokenCap=\(contextTokenCap) topChunkCount=\(selected.topChunks.count)")

        do {
            let instructions = buildInstructions(for: language)
            let session = LanguageModelSession(instructions: instructions)
            let maxOutputCharacters = TokenBudgeting.estimatedOutputCharacters(forTokens: effectiveMaxOutputTokens)
            let prompt = buildPrompt(
                for: message,
                selectedContext: finalSelectedContext,
                language: language,
                maxOutputCharacters: maxOutputCharacters,
                maxOutputTokens: effectiveMaxOutputTokens
            )
            let options = GenerationOptions(temperature: temperature, maximumResponseTokens: effectiveMaxOutputTokens)
            let response = try await session.respond(to: prompt, options: options)
            let content = normalizeModelOutput(String(describing: response.content))
            let citations = RAGCitationFormatter.citationBlock(from: selected.topChunks, language: language)
            messages.append(ChatMessage(role: .assistant, content: content, citations: citations))
            persistMessage(role: "assistant", content: content, citations: citations)
        } catch {
            let fallback = "I couldn't generate a response with the foundation model right now. Please try again."
            messages.append(ChatMessage(role: .assistant, content: fallback))
            persistMessage(role: "assistant", content: fallback, citations: nil)
            errorMessage = error.localizedDescription
        }
    }

    /// Pre-analyzes context in the background so send-time latency remains low.
    func preAnalyzeContext(contextInput: String, pdfURLs: [URL], includeWebSearch: Bool, maxContextTokens: Int) async {
        let contextKey = makeContextKey(
            contextInput: contextInput,
            pdfURLs: pdfURLs,
            includeWebSearch: includeWebSearch,
            searchQuerySeed: ""
        )
        if contextKey.isEmpty {
            preAnalyzedContextKey = nil
            preAnalyzedChunks = []
            preAnalyzedMaxContextTokens = nil
            isAnalyzingContext = false
            contextAnalysisProgress = 0
            return
        }
        if contextKey == preAnalyzedContextKey,
           maxContextTokens == preAnalyzedMaxContextTokens {
            return
        }

        isAnalyzingContext = true
        contextAnalysisProgress = 0
        debugContext("preAnalyzeContext started for pdfCount=\(pdfURLs.count)")
        let chunks = await collectChunks(
            contextInput: contextInput,
            pdfURLs: pdfURLs,
            includeWebSearch: includeWebSearch,
            currentMessage: "",
            maxContextTokens: maxContextTokens,
            reportProgress: true
        )
        preAnalyzedContextKey = contextKey
        preAnalyzedChunks = chunks
        preAnalyzedMaxContextTokens = maxContextTokens
        debugContext("preAnalyzeContext completed chunkCount=\(chunks.count)")
    }

    /// Clears conversation and cached context analysis so a new chat starts cleanly.
    func resetConversation() {
        pendingSaveTask?.cancel()
        finalizeCurrentConversation()
        messages = []
        errorMessage = nil
        isResponding = false
        isAnalyzingContext = false
        contextAnalysisProgress = 0
        preAnalyzedContextKey = nil
        preAnalyzedChunks = []
        preAnalyzedMaxContextTokens = nil
        currentConversation = nil
    }

    /// Collects web and PDF chunks from provided context.
    private func collectChunks(
        contextInput: String,
        pdfURLs: [URL],
        includeWebSearch: Bool,
        currentMessage: String = "",
        maxContextTokens: Int,
        reportProgress: Bool = false
    ) async -> [RAGChunk] {
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

        let contextURLs = extractURLs(from: contextInput)
        var discoveredURLs: [String] = []
        // DuckDuckGo discovery is send-time only because it needs the current user query.
        if includeWebSearch && !currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let searchQuery = buildWebSearchQuery(
                currentMessage: currentMessage,
                contextInput: contextInput
            )
            discoveredURLs = await discoverWebURLs(for: searchQuery)
        }
        let urls = deduplicatedURLs(contextURLs + discoveredURLs)
        let uniquePDFs = Array(Set(pdfURLs))
        let totalWorkItems = max(urls.count + uniquePDFs.count, 1)
        var completedWorkItems = 0
        let webScrapingCharacters = webScrapingCharacterBudget(forContextTokens: maxContextTokens)

        if !urls.isEmpty {
            let scraped = await webScraper.scrapeMultiplePages(
                urls: urls,
                limit: min(urls.count, Self.maxWebContextURLs),
                maxCharacters: webScrapingCharacters
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
            debugContext("collectChunks pdf=\(pdfURL.lastPathComponent) extractedPages=\(pageTexts.count)")
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

    private func buildWebSearchQuery(currentMessage: String, contextInput: String) -> String {
        let recentMessages = messages.suffix(Self.maxRecentMessagesForWebSearch)
            .filter { $0.role == .user || $0.role == .assistant }
            .map(\.content)
            .joined(separator: ". ")

        let combined = [
            currentMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            recentMessages.trimmingCharacters(in: .whitespacesAndNewlines),
            contextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return String(combined.prefix(Self.maxWebSearchQueryLength))
    }

    private func discoverWebURLs(for query: String) async -> [String] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        do {
            let results = try await webSearchService.search(query: trimmedQuery, maxResults: Self.maxWebContextURLs)
            let urls = results.map(\.url).filter {
                guard let scheme = URL(string: $0)?.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
            return Array(Set(urls))
        } catch {
            debugContext("discoverWebURLs failed for query=\"\(trimmedQuery)\": \(error.localizedDescription)")
            return []
        }
    }

    /// Returns a stable key used to reuse pre-analyzed context.
    private func makeContextKey(
        contextInput: String,
        pdfURLs: [URL],
        includeWebSearch: Bool,
        searchQuerySeed: String
    ) -> String {
        let normalizedContext = contextInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPDFPaths = Array(Set(pdfURLs.map(\.path))).sorted().joined(separator: "|")
        let normalizedQuerySeed = includeWebSearch
            ? searchQuerySeed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : ""
        if normalizedContext.isEmpty && normalizedPDFPaths.isEmpty && normalizedQuerySeed.isEmpty {
            return ""
        }
        return "\(normalizedContext)||\(normalizedPDFPaths)||web:\(includeWebSearch)||query:\(normalizedQuerySeed)"
    }

    private func deduplicatedURLs(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.filter { url in
            let normalized = normalizedURLString(url)
            return seen.insert(normalized).inserted
        }
    }

    private func normalizedURLString(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else {
            return rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
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

        guard let document = PDFDocument(url: url) else {
            debugContext("extractPDFPageTexts failed to open PDF at path=\(url.path)")
            return []
        }

        if document.isLocked, document.unlock(withPassword: "") {
            debugContext("extractPDFPageTexts unlocked a PDF with empty password")
        }
        var pages: [String] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let pageString = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageString.isEmpty {
                pages.append(pageString)
                continue
            }
            if let attributedPageString = page.attributedString?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !attributedPageString.isEmpty {
                pages.append(attributedPageString)
            }
        }

        if pages.isEmpty,
           let documentText = document.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !documentText.isEmpty {
            debugContext("extractPDFPageTexts using document-level fallback text for \(url.lastPathComponent)")
            pages.append(documentText)
        }

        if pages.isEmpty {
            debugContext("extractPDFPageTexts attempting OCR fallback for image-only PDF")
            pages = extractPDFPageTextsWithOCR(from: document)
            debugContext("extractPDFPageTexts OCR fallback extractedPages=\(pages.count)")
        }

        return pages
    }

    /// Fallback OCR extraction for image-only PDFs.
    private func extractPDFPageTextsWithOCR(from document: PDFDocument) -> [String] {
        var pages: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let pageText = recognizeText(in: page) else { continue }
            pages.append(pageText)
        }
        return pages
    }

    /// Runs Vision OCR on a rendered PDF page and returns recognized text.
    private func recognizeText(in page: PDFPage) -> String? {
        let pageBounds = page.bounds(for: .mediaBox)
        let pageSize = pageBounds.size
        let maxSide: CGFloat = 2000
        let scale = max(pageSize.width, pageSize.height) > maxSide
            ? (maxSide / max(pageSize.width, pageSize.height))
            : 1
        let targetSize = CGSize(
            width: max(1, pageSize.width * scale),
            height: max(1, pageSize.height * scale)
        )
        let image = page.thumbnail(of: targetSize, for: .mediaBox)
        #if os(macOS)
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        let cgImage = image.cgImage
        #endif
        guard let cgImage else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["fr-FR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            debugContext("OCR request failed: \(error.localizedDescription)")
            return nil
        }

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func debugContext(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ChatService][Context] \(message())")
        #endif
    }

    /// Clamps requested output tokens to fit the shared 4096-token context window budget.
    private func calculateEffectiveMaxOutputTokens(_ requestedMaxTokens: Int) -> Int {
        TokenBudgeting.clampedOutputTokens(
            requestedMaxTokens: requestedMaxTokens,
            instructionTokens: TokenBudgeting.instructionTokens,
            promptOverheadTokens: TokenBudgeting.promptOverheadTokens,
            minContextTokens: TokenBudgeting.minContextTokens
        )
    }

    private func clampContextTokens(_ requestedTokens: Int) -> Int {
        min(max(requestedTokens, AppSettings.maxContextTokensRange.lowerBound), AppSettings.maxContextTokensRange.upperBound)
    }

    private func webScrapingCharacterBudget(forContextTokens contextTokens: Int) -> Int {
        let clampedTokens = clampContextTokens(contextTokens)
        let approxContextChars = TokenBudgeting.estimatedContextCharacters(forTokens: clampedTokens)
        let scrapeBudget = approxContextChars * 2
        return min(max(scrapeBudget, Self.minWebScrapingCharacters), Self.maxWebScrapingCharacters)
    }

    /// Builds the model prompt from recent history and retrieved context.
    private func buildPrompt(
        for userMessage: String,
        selectedContext: String,
        language: ModelLanguage,
        maxOutputCharacters: Int,
        maxOutputTokens: Int
    ) -> String {
        let historyMessages: [ChatMessage]
        if let last = messages.last, last.role == .user, last.content == userMessage {
            historyMessages = Array(messages.dropLast())
        } else {
            historyMessages = messages
        }

        let history = historyMessages
            .suffix(Self.historyMessageLimit)
            .map { item in
                if item.role == .assistant {
                    return "Assistant: \(sanitizeLaTeXDocumentWrappers(item.content))"
                }
                return "User: \(item.content)"
            }
            .joined(separator: "\n")

        return PromptLoader.loadPrompt(
            mode: "normal",
            feature: "chat",
            language: language,
            replacements: [
                "history": history,
                "context": selectedContext,
                "question": userMessage,
                "maxOutputCharacters": "\(maxOutputCharacters)",
                "maxOutputTokens": "\(maxOutputTokens)"
            ]
        ) ?? fallbackChatPrompt(
            history: history,
            selectedContext: selectedContext,
            userMessage: userMessage,
            language: language,
            maxOutputCharacters: maxOutputCharacters,
            maxOutputTokens: maxOutputTokens
        )
    }

    /// Removes full LaTeX document wrappers that the renderer does not expect.
    private func sanitizeLaTeXDocumentWrappers(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let beginRange = cleaned.range(of: "\\begin{document}"),
           let endRange = cleaned.range(of: "\\end{document}"),
           beginRange.upperBound <= endRange.lowerBound {
            cleaned = String(cleaned[beginRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s*\\documentclass(?:\[[^\]]*\])?\{[^}]*\}\s*$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s*\\usepackage(?:\[[^\]]*\])?\{[^}]*\}\s*$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\\begin{document}", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\\end{document}", with: "")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes escaped sequences emitted by the model so Markdown/KaTeX render correctly.
    private func normalizeModelOutput(_ raw: String) -> String {
        var normalized = raw
        normalized = normalized.replacingOccurrences(of: "\\\\", with: "\\")
        normalized = normalized.replacingOccurrences(of: "\\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\\t", with: "\t")
        normalized = normalized.replacingOccurrences(of: "\\r", with: "\r")
        normalized = normalized.replacingOccurrences(of: "\\$", with: "$")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds dynamic chat instructions matching the user's query language.
    private func buildInstructions(for language: ModelLanguage) -> String {
        return PromptLoader.loadPrompt(mode: "normal", feature: "chat", variant: "instructions", language: language)
            ?? fallbackChatInstructions(for: language)
    }

    private func fallbackChatInstructions(for language: ModelLanguage) -> String {
        if language == .french {
            return """
            Vous êtes un assistant de chat utile. Répondez clairement et précisément.
            Utilisez le contexte récupéré lorsqu'il est pertinent et indiquez vos incertitudes si le contexte est insuffisant.
            Répondez dans la même langue que la question de l'utilisateur (ici: français).
            """
        }

        return """
        You are a helpful chat assistant. Answer the user clearly and accurately.
        Use retrieved context when relevant and mention uncertainty when context is insufficient.
        Respond in the same language as the user's latest question.
        """
    }

    private func fallbackChatPrompt(
        history: String,
        selectedContext: String,
        userMessage: String,
        language: ModelLanguage,
        maxOutputCharacters: Int,
        maxOutputTokens: Int
    ) -> String {
        if language == .french {
            return """
            Conversation :
            \(history)

            Contexte récupéré :
            \(selectedContext)

            Question de l'utilisateur :
            \(userMessage)

            Réponds de façon concise et pratique.
            Limite de sortie : \(maxOutputTokens) tokens maximum (environ \(maxOutputCharacters) caractères).
            Quand c'est pertinent, inclus des expressions ou formules mathématiques.
            Format de sortie attendu : LaTeX pour les expressions mathématiques.
            Règles de format math :
            - Utilise $...$ pour l'inline.
            - Utilise \\[...\\] pour les blocs.
            - Utilise un LaTeX simple compatible avec le rendu de l'application.
            - N'utilise jamais d'environnements \\begin{.
            """
        }

        return """
        Conversation:
        \(history)

        Retrieved Context:
        \(selectedContext)

        User question:
        \(userMessage)

        Answer in a concise and practical way.
        Output limit: \(maxOutputTokens) tokens maximum (about \(maxOutputCharacters) characters).
        When relevant, include mathematical expressions or formulas.
        Required output format: LaTeX for mathematical expressions.
        Math format requirements:
        - Use $...$ for inline math.
        - Use \\[...\\] for block math.
        - Use simple LaTeX compatible with the app renderer.
        - Never use environments with \\begin{.
        """
    }

    /// Persists a message to the current SwiftData conversation.
    private func persistMessage(role: String, content: String, citations: String?) {
        guard let modelContext else { return }

        // Create conversation if needed
        if currentConversation == nil {
            let conv = Conversation(
                messages: [],
                title: role == "user" ? generateTitle(from: content) : nil
            )
            currentConversation = conv
            modelContext.insert(conv)
        }

        guard let conversation = currentConversation else { return }

        // Create and add message
        let message = Message(role: role, content: content, citations: citations)
        conversation.messages.append(message)
        conversation.updatedAt = Date()

        scheduleContextSave()
    }

    /// Auto-generates a title from the first user message.
    private func generateTitle(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 50
        if trimmed.count <= maxLength {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<index]) + "..."
    }

    /// Finalizes the current conversation by auto-generating a title if needed.
    private func finalizeCurrentConversation() {
        guard let modelContext, let conversation = currentConversation, !conversation.messages.isEmpty else { return }

        // Auto-generate title from first user message if not set
        if conversation.title == nil {
            if let firstUserMessage = conversation.messages.first(where: { $0.role == "user" }) {
                conversation.title = generateTitle(from: firstUserMessage.content)
            }
        }

        pendingSaveTask?.cancel()
        _ = saveContext(modelContext)
    }

    /// Saves the current SwiftData context and reports failures in debug builds.
    @discardableResult
    private func saveContext(_ modelContext: ModelContext) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            #if DEBUG
            print("[ChatService][Persistence] Failed to save model context: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Debounces persistence writes to avoid saving on every single appended message.
    @MainActor private func scheduleContextSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.saveDebounceIntervalNanoseconds)
            } catch {
                return
            }
            guard let self else {
                #if DEBUG
                print("[ChatService][Persistence] Skipped save: ChatService deallocated before debounced save.")
                #endif
                return
            }
            guard let modelContext = self.modelContext else {
                #if DEBUG
                print("[ChatService][Persistence] Skipped save: modelContext unavailable.")
                #endif
                return
            }
            _ = self.saveContext(modelContext)
        }
    }

    /// Loads a previous conversation by ID and syncs it to the UI.
    func loadConversation(id: UUID) {
        guard let modelContext else { return }

        // Find the conversation
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        guard let conversation = try? modelContext.fetch(descriptor).first else { return }

        currentConversation = conversation

        // Convert SwiftData messages to ChatMessage for UI
        messages = conversation.messages
            .sorted { $0.timestamp < $1.timestamp }
            .map { ChatMessage(role: $0.role == "user" ? .user : .assistant, content: $0.content, citations: $0.citations) }
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
    let citations: String?

    init(role: Role, content: String, citations: String? = nil) {
        self.role = role
        self.content = content
        self.citations = citations
    }
}
