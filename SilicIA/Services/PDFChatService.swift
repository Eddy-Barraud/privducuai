//
//  PDFChatService.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import Foundation
import Combine
import SwiftData
import FoundationModels
import PDFKit
import Vision
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

typealias PDFKitDocument = PDFKit.PDFDocument

/// Service layer for PDF-specific retrieval-augmented chat generation.
/// Focuses on a single PDF document with emphasis on page citations.
@MainActor
final class PDFChatService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isResponding = false
    @Published var errorMessage: String?
    @Published var isAnalyzingContext = false
    @Published var contextAnalysisProgress = 0.0
    @Published var currentPDF: PDFDocumentInfo?
    @Published var highlightedChunks: [RAGChunk] = []

    private let ragContextService = RAGContextService()

    // SwiftData persistence
    var modelContext: ModelContext?
    private var currentConversation: PDFConversation?
    private var isCurrentConversationInserted = false
    private var pendingSaveTask: Task<Void, Never>?

    private nonisolated static let pdfChunkMaxTokens = 220
    private nonisolated static let pdfChunkOverlapTokens = 30
    private nonisolated static let historyMessageLimit = 6
    private nonisolated static let saveDebounceIntervalNanoseconds: UInt64 = 250_000_000
    private var preAnalyzedContextKey: String?
    private var preAnalyzedChunks: [RAGChunk] = []
    private var preAnalyzedMaxContextTokens: Int?

    private struct ProcessedPDFData: Sendable {
        let pageCount: Int
        let extractedChunks: [RAGChunk]
    }

    /// Loads a PDF and extracts its content into chunks.
    func loadPDF(_ url: URL) async {
        var document = PDFDocumentInfo(url: url)
        document.loadingStatus = .loading
        currentPDF = document

        do {
            let processed = try await Task.detached(priority: .userInitiated) {
                try await Self.processPDF(at: url)
            }.value

            document.pageCount = processed.pageCount
            document.extractedChunks = processed.extractedChunks
            document.loadingStatus = .loaded
            currentPDF = document
            preAnalyzedChunks = processed.extractedChunks
            preAnalyzedContextKey = url.absoluteString
            preAnalyzedMaxContextTokens = nil

            // Reset conversation for new PDF
            resetConversation(keepCurrentPDFContext: true)
        } catch is CancellationError {
            currentPDF?.loadingStatus = .error("PDF loading was cancelled")
        } catch {
            currentPDF?.loadingStatus = .error(error.localizedDescription)
        }
    }

    /// Sends a user message and appends the assistant response with PDF context.
    func sendMessage(
        _ message: String,
        language: ModelLanguage,
        temperature: Double,
        maxResponseTokens: Int,
        maxContextTokens: Int
    ) async {
        guard let pdfDocument = currentPDF, pdfDocument.loadingStatus == .loaded else {
            errorMessage = "PDF not loaded"
            return
        }

        messages.append(ChatMessage(role: .user, content: message))
        persistMessage(role: "user", content: message, citations: nil)
        errorMessage = nil

        isResponding = true
        defer { isResponding = false }

        let effectiveMaxOutputTokens = calculateEffectiveMaxOutputTokens(maxResponseTokens)
        preAnalyzedMaxContextTokens = maxContextTokens

        // Use pre-analyzed chunks from PDF
        let chunks = preAnalyzedChunks.isEmpty ? pdfDocument.extractedChunks : preAnalyzedChunks

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

        // Keep the exact context chunks used for this answer.
        let usedSourceChunks = selected.topChunks.map { $0.chunk }

        do {
            let instructions = buildInstructions(for: language, pdfTitle: pdfDocument.fileName, pageCount: pdfDocument.pageCount)
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
            let citationAnalysis = PDFAnswerAnalyzer.analyzeCitations(in: content, sourceChunks: usedSourceChunks)
            let answerSourceChunks = citationAnalysis.citedChunks.isEmpty ? usedSourceChunks : citationAnalysis.citedChunks
            highlightedChunks = answerSourceChunks

            // Format citations with PDF page numbers
            let citations = RAGCitationFormatter.pdfCitationBlock(from: selected.topChunks, language: language)

            messages.append(ChatMessage(role: .assistant, content: content, citations: citations, sourceChunks: answerSourceChunks))
            persistMessage(role: "assistant", content: content, citations: citations)
        } catch {
            let fallback = "I couldn't generate a response with the foundation model right now. Please try again."
            messages.append(ChatMessage(role: .assistant, content: fallback))
            persistMessage(role: "assistant", content: fallback, citations: nil)
            errorMessage = error.localizedDescription
        }
    }

    /// Highlights specified chunks in the PDF (for UI to display).
    func setHighlightedChunks(_ chunks: [RAGChunk]) {
        highlightedChunks = chunks
    }

    /// Clears conversation and cached context.
    func resetConversation(keepCurrentPDFContext: Bool = false) {
        pendingSaveTask?.cancel()
        finalizeCurrentConversation()
        messages = []
        errorMessage = nil
        isResponding = false
        highlightedChunks = []
        if !keepCurrentPDFContext {
            preAnalyzedContextKey = nil
            preAnalyzedChunks = []
            preAnalyzedMaxContextTokens = nil
        }
        currentConversation = nil
        isCurrentConversationInserted = false
    }

    /// Clears the current chat and loaded PDF state.
    func clearCurrentChat() {
        resetConversation(keepCurrentPDFContext: false)
        currentPDF = nil
    }

    /// Loads a previous PDF conversation.
    func loadConversation(_ conversation: PDFConversation) {
        currentConversation = conversation
        isCurrentConversationInserted = true
        messages = conversation.messages.sorted { $0.timestamp < $1.timestamp }.map {
            ChatMessage(role: $0.role == "user" ? .user : .assistant, content: $0.content, citations: $0.citations)
        }
    }

    // MARK: - Private Methods

    private nonisolated static func processPDF(at url: URL) async throws -> ProcessedPDFData {
        guard let pdfDocument = PDFKitDocument(url: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let pageTexts = try await extractPDFPageTexts(from: pdfDocument)
        let ragChunker = RAGChunker()
        var allChunks: [RAGChunk] = []

        for (pageIndex, pageText) in pageTexts.enumerated() {
            try Task.checkCancellation()

            if !pageText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                let chunks = ragChunker.chunk(
                    text: pageText,
                    source: url.lastPathComponent,
                    maxChunkTokens: Self.pdfChunkMaxTokens,
                    overlapTokens: Self.pdfChunkOverlapTokens,
                    url: nil,
                    pdfPage: pageIndex + 1
                )
                allChunks.append(contentsOf: chunks)
            }
        }

        return ProcessedPDFData(
            pageCount: pdfDocument.pageCount,
            extractedChunks: allChunks
        )
    }

    private nonisolated static func extractPDFPageTexts(from pdfDocument: PDFKitDocument) async throws -> [String] {
        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pdfDocument.pageCount)

        for pageIndex in 0..<pdfDocument.pageCount {
            try Task.checkCancellation()
            let text = try await extractPageText(from: pdfDocument, pageIndex: pageIndex)
            pageTexts.append(text)
        }

        return pageTexts
    }

    private nonisolated static func extractPageText(from pdfDocument: PDFKitDocument, pageIndex: Int) async throws -> String {
        guard let page = pdfDocument.page(at: pageIndex) else { return "" }

        // Try direct text extraction first
        if let text = page.string, !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return text
        }

        // Fallback to OCR for image-only pages
        let pageImage = renderPageAsImage(pdfDocument, pageIndex: pageIndex)
        if let image = pageImage {
            return performOCR(on: image)
        }

        return ""
    }

    private nonisolated static func renderPageAsImage(_ pdfDocument: PDFKitDocument, pageIndex: Int) -> CGImage? {
        let scale = CGFloat(2.0)
        let bounds = CGRect(
            x: 0, y: 0,
            width: 612 * scale, height: 792 * scale
        )

        guard let page = pdfDocument.page(at: pageIndex) else { return nil }

        let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        guard let context = context else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)

        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        page.draw(with: PDFDisplayBox.mediaBox, to: context)

        return context.makeImage()
    }

    private nonisolated static func performOCR(on image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US", "fr-FR"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return ""
            }

            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            return text
        } catch {
            return ""
        }
    }

    private func calculateEffectiveMaxOutputTokens(_ maxResponseTokens: Int) -> Int {
        let clamped = max(500, min(maxResponseTokens, 2000))
        return clamped
    }

    private func clampContextTokens(_ contextTokens: Int) -> Int {
        max(300, min(contextTokens, 3500))
    }

    private func buildInstructions(for language: ModelLanguage, pdfTitle: String = "", pageCount: Int = 0) -> String {
        let promptFile = language == .french ? "prompt.pdf.chat.instructions.fr" : "prompt.pdf.chat.instructions.en"
        var instructions = PromptLoader.loadPrompt(named: promptFile) ?? ""

        instructions = instructions
            .replacingOccurrences(of: "{{pdf_title}}", with: pdfTitle)
            .replacingOccurrences(of: "{{page_count}}", with: "\(pageCount)")

        return instructions
    }

    private func buildPrompt(
        for userMessage: String,
        selectedContext: String,
        language: ModelLanguage,
        maxOutputCharacters: Int,
        maxOutputTokens: Int
    ) -> String {
        let recentMessages = messages.suffix(Self.historyMessageLimit)
        let history = recentMessages.map { msg -> String in
            let role = msg.role == .user ? "User" : "Assistant"
            return "\(role): \(msg.content)"
        }
        .joined(separator: "\n\n")

        let promptFile = language == .french ? "prompt.pdf.chat.fr" : "prompt.pdf.chat.en"
        var prompt = PromptLoader.loadPrompt(named: promptFile) ?? ""

        prompt = prompt
            .replacingOccurrences(of: "{{history}}", with: history)
            .replacingOccurrences(of: "{{context}}", with: selectedContext)
            .replacingOccurrences(of: "{{question}}", with: userMessage)
            .replacingOccurrences(of: "{{maxOutputTokens}}", with: "\(maxOutputTokens)")
            .replacingOccurrences(of: "{{maxOutputCharacters}}", with: "\(maxOutputCharacters)")

        return prompt
    }

    private func normalizeModelOutput(_ text: String) -> String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistMessage(role: String, content: String, citations: String?) {
        let message = Message(role: role, content: content, citations: citations)

        if currentConversation == nil {
            let conversation = PDFConversation(
                pdfSourceURL: currentPDF?.url ?? URL(fileURLWithPath: ""),
                pdfFileName: currentPDF?.fileName ?? "",
                pdfPageCount: currentPDF?.pageCount ?? 0
            )
            if let title = title(from: content, isUser: role == "user") {
                conversation.title = title
            }

            currentConversation = conversation

            if let context = modelContext {
                context.insert(conversation)
                isCurrentConversationInserted = true
            } else {
                isCurrentConversationInserted = false
            }
        }

        currentConversation?.messages.append(message)
        currentConversation?.updatedAt = Date()
        scheduleContextSave()
    }

    private func scheduleContextSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            let nanoseconds = Self.saveDebounceIntervalNanoseconds
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard !Task.isCancelled else { return }
            finalizeCurrentConversation()
        }
    }

    private func finalizeCurrentConversation() {
        guard let conversation = currentConversation, let context = modelContext else { return }

        do {
            if !isCurrentConversationInserted {
                context.insert(conversation)
                isCurrentConversationInserted = true
            }
            try context.save()
        } catch {
            errorMessage = "Failed to save conversation: \(error.localizedDescription)"
        }
    }

    private func title(from content: String, isUser: Bool) -> String? {
        guard isUser, currentConversation?.title == nil else { return nil }
        let maxLength = 50
        let truncated = content.count > maxLength ? String(content.prefix(maxLength)) + "..." : content
        return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
