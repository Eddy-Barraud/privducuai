//
//  PDFChatService.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import Foundation
import FoundationModels
import Combine
import PDFKit
import Vision

@MainActor
final class PDFChatService: ObservableObject {
    @Published var messages: [PDFChatMessage] = []
    @Published var isResponding = false
    @Published var errorMessage: String?

    private let ragChunker = RAGChunker()
    private let ragContextService = RAGContextService()

    private static let pdfChunkMaxTokens = 220
    private static let pdfChunkOverlapTokens = 30

    func reset() {
        messages = []
        isResponding = false
        errorMessage = nil
    }

    func sendMessage(
        _ message: String,
        pdfURL: URL?,
        prioritizedSelectionText: String?,
        settings: AppSettings
    ) async {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        messages.append(PDFChatMessage(role: .user, content: trimmedMessage))
        isResponding = true
        errorMessage = nil
        defer { isResponding = false }

        let effectiveMaxOutputTokens = TokenBudgeting.clampedOutputTokens(
            requestedMaxTokens: settings.maxResponseTokens,
            instructionTokens: TokenBudgeting.instructionTokens,
            promptOverheadTokens: TokenBudgeting.promptOverheadTokens,
            minContextTokens: TokenBudgeting.minContextTokens
        )
        let effectiveMaxContextTokens = TokenBudgeting.clampedContextTokens(
            requestedContextTokens: settings.maxContextTokens,
            maxOutputTokens: effectiveMaxOutputTokens,
            settingsRange: AppSettings.maxContextTokensRange,
            instructionTokens: TokenBudgeting.instructionTokens,
            promptOverheadTokens: TokenBudgeting.promptOverheadTokens,
            minContextTokens: TokenBudgeting.minContextTokens
        )

        var chunks: [RAGChunk] = []

        if let pdfURL {
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
        }

        let normalizedPriority = prioritizedSelectionText?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedPriority, !normalizedPriority.isEmpty {
            let priorityChunks = ragChunker.chunk(
                text: normalizedPriority,
                source: "User Selection",
                maxChunkTokens: Self.pdfChunkMaxTokens,
                overlapTokens: 0,
                boostRankOne: true
            )
            chunks.append(contentsOf: priorityChunks)
        }

        let selected = await ragContextService.selectContext(
            chunks: chunks,
            query: trimmedMessage,
            maxOutputTokens: effectiveMaxOutputTokens,
            contextUtilizationFactor: RAGSelectionOptions.default.contextUtilizationFactor
        )

        let contextTokenCap = effectiveMaxContextTokens
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

        do {
            let session = LanguageModelSession(instructions: buildInstructions(for: settings.language))
            let maxOutputCharacters = TokenBudgeting.estimatedOutputCharacters(forTokens: effectiveMaxOutputTokens)
            let prompt = buildPrompt(
                userMessage: trimmedMessage,
                selectedContext: finalSelectedContext,
                language: settings.language,
                maxOutputCharacters: maxOutputCharacters,
                maxOutputTokens: effectiveMaxOutputTokens
            )
            let options = GenerationOptions(
                temperature: settings.temperature,
                maximumResponseTokens: effectiveMaxOutputTokens
            )
            let response = try await session.respond(to: prompt, options: options)
            let content = normalizeModelOutput(String(describing: response.content))
            let citations = RAGCitationFormatter.citationBlock(from: selected.topChunks, language: settings.language)
            messages.append(PDFChatMessage(role: .assistant, content: content, citations: citations))
        } catch {
            let fallback = "I couldn't generate a response with the foundation model right now. Please try again."
            messages.append(PDFChatMessage(role: .assistant, content: fallback))
            errorMessage = error.localizedDescription
        }
    }

    private func extractPDFPageTexts(from url: URL) -> [String] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: url) else {
            return []
        }

        if document.isLocked {
            _ = document.unlock(withPassword: "")
        }

        var pages: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let pageString = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageString.isEmpty {
                pages.append(pageString)
                continue
            }
            if let attributedString = page.attributedString?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !attributedString.isEmpty {
                pages.append(attributedString)
            }
        }

        if pages.isEmpty,
           let documentText = document.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !documentText.isEmpty {
            pages.append(documentText)
        }

        if pages.isEmpty {
            pages = extractPDFPageTextsWithOCR(from: document)
        }

        return pages
    }

    private func extractPDFPageTextsWithOCR(from document: PDFDocument) -> [String] {
        var pages: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let pageText = recognizeText(in: page) else { continue }
            pages.append(pageText)
        }
        return pages
    }

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
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
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
            return nil
        }

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func buildInstructions(for language: ModelLanguage) -> String {
        PromptLoader.loadPrompt(mode: "normal", feature: "chat", variant: "instructions", language: language)
            ?? fallbackInstructions(for: language)
    }

    private func buildPrompt(
        userMessage: String,
        selectedContext: String,
        language: ModelLanguage,
        maxOutputCharacters: Int,
        maxOutputTokens: Int
    ) -> String {
        let history = messages
            .suffix(6)
            .map { item in
                item.role == .assistant
                ? "Assistant: \(item.content)"
                : "User: \(item.content)"
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
        ) ?? fallbackPrompt(
            history: history,
            selectedContext: selectedContext,
            userMessage: userMessage,
            language: language,
            maxOutputCharacters: maxOutputCharacters,
            maxOutputTokens: maxOutputTokens
        )
    }

    private func normalizeModelOutput(_ raw: String) -> String {
        var normalized = raw
        normalized = normalized.replacingOccurrences(of: "\\\\", with: "\\")
        normalized = normalized.replacingOccurrences(of: "\\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\\t", with: "\t")
        normalized = normalized.replacingOccurrences(of: "\\r", with: "\r")
        normalized = normalized.replacingOccurrences(of: "\\$", with: "$")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fallbackInstructions(for language: ModelLanguage) -> String {
        if language == .french {
            return """
            Vous êtes un assistant utile spécialisé dans les PDF.
            Utilisez prioritairement le contexte fourni, surtout les extraits marqués comme rang 1.
            Signalez clairement quand l'information n'est pas dans le document.
            """
        }

        return """
        You are a helpful assistant specialized in PDF question answering.
        Prioritize provided context, especially excerpts explicitly marked as rank 1.
        Clearly state when the document does not contain the requested information.
        """
    }

    private func fallbackPrompt(
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

            Contexte PDF récupéré :
            \(selectedContext)

            Question :
            \(userMessage)

            Réponds de façon concise.
            Limite de sortie : \(maxOutputTokens) tokens (~\(maxOutputCharacters) caractères).
            """
        }

        return """
        Conversation:
        \(history)

        Retrieved PDF context:
        \(selectedContext)

        Question:
        \(userMessage)

        Answer concisely.
        Output limit: \(maxOutputTokens) tokens (~\(maxOutputCharacters) characters).
        """
    }
}

struct PDFChatMessage: Identifiable {
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
