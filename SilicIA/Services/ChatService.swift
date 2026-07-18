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
    @Published private(set) var pdfAnalysisProgress: [String: Double] = [:]
    /// Filename of the PDF the current conversation is anchored to, if any.
    /// PDFtalkme observes this to keep its left pane in sync with whichever
    /// conversation is loaded (e.g. when the user picks one from history).
    @Published var currentConversationPDFFilename: String?
    /// Security-scoped bookmark for the same PDF, for hosts that want to
    /// resolve the file across launches.
    @Published var currentConversationPDFBookmark: Data?
    /// Normalized base filenames of every PDF currently in context, in
    /// order. The host watches this to mirror the full set of PDFs (not
    /// just the anchor) into its UI when a conversation is restored.
    @Published var currentConversationPDFFilenames: [String] = []
    /// Security-scoped bookmarks aligned to `currentConversationPDFFilenames`.
    @Published var currentConversationPDFBookmarks: [Data] = []

    private let webScraper = WebScrapingService()
    private let webSearchService = WebSearchService()
    private let ragChunker = RAGChunker()
    private let ragContextService = RAGContextService()

    // SwiftData persistence
    var modelContext: ModelContext?
    private var currentConversation: Conversation?
    private var pendingSaveTask: Task<Void, Never>?
    /// PDF URL captured from the most recent `sendMessage` call. Used by
    /// `persistMessage` to stamp a freshly created conversation with the
    /// document the user is asking about.
    private var activePDFURLForNewConversation: URL?
    /// The *full* PDF context list from the most recent `sendMessage` call.
    /// Stamped onto a freshly created conversation, and synced onto an
    /// existing conversation so it always reflects whatever PDFs the
    /// composer currently has attached.
    private var activePDFURLsForNewConversation: [URL] = []

    // Keep web retrieval bounded to control latency and context size.
    private static let maxWebContextURLCap = 30
    // Chunk sizes tuned to preserve locality while allowing many chunks in a 4096-token budget.
    private static let webChunkMaxTokens = 240
    private static let webChunkOverlapTokens = 40
    private static let pdfChunkMaxTokens = 220
    private static let pdfChunkOverlapTokens = 30
    private static let pdfWholePageContextFraction = 0.9
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
    private var preAnalyzedMaxOutputTokens: Int?
    private var preAnalyzedMaxDuckDuckGoResults: Int?
    private var preAnalyzedMaxWikipediaResults: Int?
    private var preAnalyzedUseDuckDuckGo: Bool = true
    private var preAnalyzedUseWikipedia: Bool = true
    private var preAnalyzedUseWebVision: Bool = false

    nonisolated static func contextAttachmentKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Sends a user message and appends the assistant response.
    func sendMessage(
        _ message: String,
        contextInput: String,
        pdfURLs: [URL],
        imageURLs: [URL] = [],
        includeWebSearch: Bool,
        maxDuckDuckGoResults: Int,
        maxWikipediaResults: Int,
        language: ModelLanguage,
        temperature: Double,
        maxResponseTokens: Int,
        maxContextTokens: Int,
        useDuckDuckGo: Bool = true,
        useWikipedia: Bool = true,
        useToolCalling: Bool = false,
        useWebVision: Bool = false
    ) async {
        activePDFURLForNewConversation = pdfURLs.first
        activePDFURLsForNewConversation = pdfURLs
        syncCurrentConversationPDFs(with: pdfURLs)
        messages.append(ChatMessage(role: .user, content: message))
        persistMessage(role: "user", content: message, citations: nil)
        errorMessage = nil

        isResponding = true
        defer { isResponding = false }

        let availability = FoundationModelAvailability.check()
        if case .unavailable(let reason) = availability {
            let assistantID = UUID()
            messages.append(ChatMessage(id: assistantID, role: .assistant, content: "", citations: nil, modelAvailabilityReason: reason))
            persistMessage(role: "assistant", content: "", citations: nil, modelAvailabilityReason: reason.stringValue)
            return
        }

        // Compute every effective/clamped value ONCE up front and reuse for the
        // cache key, the cache-hit comparison, and downstream calls. Clamping
        // is idempotent, but doing it twice (once for the key, once after) was
        // wasteful and made the cache key risk going out of sync with the
        // values actually used.
        let effectiveMaxDDGResults = clampedMaxDuckDuckGoResults(maxDuckDuckGoResults)
        let effectiveMaxWikiResults = clampedMaxWikipediaResults(maxWikipediaResults)
        let effectiveMaxOutputTokens = calculateEffectiveMaxOutputTokens(
            maxResponseTokens,
            useToolCalling: useToolCalling
        )
        let effectiveMaxContextTokens = calculateEffectiveContextTokens(
            requestedContextTokens: maxContextTokens,
            maxOutputTokens: effectiveMaxOutputTokens
        )

        // Tool-calling mode: the model owns the decision to search the web,
        // via the `webSearch` tool. Suppress the auto-prefetch path so we
        // don't redundantly fetch + chunk pages the model might not even
        // care about. The user's "Web" chip in the composer is therefore
        // a no-op when tool calling is on — the prompt-stuffing baseline
        // still honours it.
        let effectiveIncludeWebSearch = useToolCalling ? false : includeWebSearch
        let contextKey = makeContextKey(
            contextInput: contextInput,
            pdfURLs: pdfURLs,
            imageURLs: imageURLs,
            includeWebSearch: effectiveIncludeWebSearch,
            useWebVision: useWebVision,
            searchQuerySeed: effectiveIncludeWebSearch ? message : "",
            clampedDuckDuckGoResults: effectiveMaxDDGResults,
            clampedWikipediaResults: effectiveMaxWikiResults
        )
        let hasRequestedContext = !contextKey.isEmpty
        let canUsePreAnalyzed = contextKey == preAnalyzedContextKey
            && effectiveMaxContextTokens == preAnalyzedMaxContextTokens
            && effectiveMaxOutputTokens == preAnalyzedMaxOutputTokens
            && effectiveMaxDDGResults == preAnalyzedMaxDuckDuckGoResults
            && effectiveMaxWikiResults == preAnalyzedMaxWikipediaResults
            && useDuckDuckGo == preAnalyzedUseDuckDuckGo
            && useWikipedia == preAnalyzedUseWikipedia
            && useWebVision == preAnalyzedUseWebVision
            && (!hasRequestedContext || !preAnalyzedChunks.isEmpty)
        debugContext("sendMessage cache=\(canUsePreAnalyzed ? "hit" : "miss") keyEmpty=\(contextKey.isEmpty) pdfCount=\(pdfURLs.count) imageCount=\(imageURLs.count) preChunks=\(preAnalyzedChunks.count)")
        let chunks: [RAGChunk]
        if canUsePreAnalyzed {
            chunks = preAnalyzedChunks
        } else {
            chunks = await collectChunks(
                contextInput: contextInput,
                pdfURLs: pdfURLs,
                imageURLs: imageURLs,
                includeWebSearch: effectiveIncludeWebSearch,
                currentMessage: message,
                language: language,
                maxDuckDuckGoResults: effectiveMaxDDGResults,
                maxWikipediaResults: effectiveMaxWikiResults,
                maxContextTokens: effectiveMaxContextTokens,
                useDuckDuckGo: useDuckDuckGo,
                useWikipedia: useWikipedia,
                useWebVision: useWebVision
            )
            preAnalyzedContextKey = contextKey
            preAnalyzedChunks = chunks
            preAnalyzedMaxContextTokens = effectiveMaxContextTokens
            preAnalyzedMaxOutputTokens = effectiveMaxOutputTokens
            preAnalyzedMaxDuckDuckGoResults = effectiveMaxDDGResults
            preAnalyzedMaxWikipediaResults = effectiveMaxWikiResults
            preAnalyzedUseDuckDuckGo = useDuckDuckGo
            preAnalyzedUseWikipedia = useWikipedia
            preAnalyzedUseWebVision = useWebVision
        }
        debugContext("sendMessage chunkCount=\(chunks.count)")
        let selected = await ragContextService.selectContext(
            chunks: chunks,
            query: message,
            maxOutputTokens: effectiveMaxOutputTokens,
            contextUtilizationFactor: RAGSelectionOptions.default.contextUtilizationFactor
        )
        // Cap the selected context with a single primary strategy:
        //   1. Word-aware truncation (semantic boundaries — preferred).
        //   2. Hard character safety-net only when (1) still exceeds the
        //      prompt-character budget that the model can ingest.
        // This replaces the prior double-cap which built two intermediate
        // Strings and picked the shorter — wasteful and harder to reason
        // about, since the two budgets are derived from the same token cap.
        let maxPromptContextCharacters = TokenBudgeting.maxContextCharacters(
            maxOutputTokens: effectiveMaxOutputTokens,
            contextUtilizationFactor: 1.0
        )
        let effectiveContextTokenCap = min(
            effectiveMaxContextTokens,
            TokenBudgeting.estimatedTokens(forApproxCharacters: maxPromptContextCharacters)
        )
        let contextWordEstimate = TokenBudgeting.estimatedContextWords(forTokens: effectiveContextTokenCap)
        var finalSelectedContext = TokenBudgeting.truncateToApproxWordCount(
            selected.selectedContext,
            maxWords: contextWordEstimate
        )
        if finalSelectedContext.count > maxPromptContextCharacters {
            finalSelectedContext = String(finalSelectedContext.prefix(maxPromptContextCharacters))
        }
        finalSelectedContext = finalSelectedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        debugContext("sendMessage contextChars raw=\(selected.selectedContext.count) capped=\(finalSelectedContext.count) tokenCap=\(effectiveMaxContextTokens) topChunks=\(selected.topChunks.count)")
        #if DEBUG
        // Full per-chunk dump of what the model is about to see. Guarded by
        // DEBUG so release builds stay silent; only the chunks that actually
        // landed in `selectedContext` are printed (i.e. survived budgeting).
        print(selected.debugDescription(label: "ChatService → chat prompt"))
        #endif

        var streamingAssistantID: UUID?
        var toolTranscriptRecorder: ToolTranscriptRecorder?
        do {
            let instructions = buildInstructions(
                for: language,
                maxOutputCharacters: TokenBudgeting.estimatedOutputCharacters(forTokens: effectiveMaxOutputTokens),
                useToolCalling: useToolCalling,
                webSearchAvailable: useToolCalling && (useDuckDuckGo || useWikipedia) && includeWebSearch
            )
            // Tool-calling branch: hand the model `searchContext` over the
            // pre-chunked corpus + `calculate` for exact arithmetic. The
            // prompt is intentionally minimal (just the user message + a
            // nudge to call the tool first) — the model pulls context on
            // demand instead of receiving a pre-baked top-K block. The
            // calculator wipes out an entire class of small-model
            // arithmetic mistakes.
            let session: LanguageModelSession
            var toolBudget = 0
            if useToolCalling {
                // Web-search tool joins the kit only when (a) at least one
                // source is enabled AND (b) the user has the "Web" chip on
                // in the composer. The chip is the per-conversation switch;
                // the source flags are the global "what to query" config.
                // Both must be true for the tool to be attached. PDFtalkme
                // forces the chip off so the tool stays off in that host.
                let webSearchAvailable = (useDuckDuckGo || useWikipedia) && includeWebSearch
                let assembled = ToolKit.assemble(
                    config: ToolKit.Configuration(
                        language: language,
                        corpusChunks: chunks,
                        webSearchAvailable: webSearchAvailable,
                        webSearchService: webSearchService,
                        webScraper: webScraper,
                        useWebVision: useWebVision,
                        maxDuckDuckGoResults: effectiveMaxDDGResults,
                        maxWikipediaResults: effectiveMaxWikiResults,
                        useDuckDuckGo: useDuckDuckGo,
                        useWikipedia: useWikipedia
                        // Chat path doesn't subscribe to webSearch results
                        // — there are no search cards in ChatView.
                    ),
                    responseTokens: effectiveMaxOutputTokens
                )
                let tools = assembled.tools
                toolBudget = assembled.tokenBudget
                toolTranscriptRecorder = assembled.transcriptRecorder
                let toolNames = tools.map(\.name).joined(separator: ", ")
                debugContext("sendMessage path=tool-calling tools=[\(toolNames)] corpusChunks=\(chunks.count) webSearchAvailable=\(webSearchAvailable) toolBudget=\(toolBudget)t")
                session = LanguageModelSession(
                    tools: tools,
                    instructions: instructions
                )
            } else {
                debugContext("sendMessage path=prompt-stuffing (tool-calling disabled)")
                session = LanguageModelSession(instructions: instructions)
            }
            let maxOutputCharacters = TokenBudgeting.estimatedOutputCharacters(forTokens: effectiveMaxOutputTokens)
            let prompt: String
            if useToolCalling {
                // Hybrid grounding: pre-bake the RAG-selected passages into
                // the prompt (like the classical path) so broad questions on
                // attached PDFs/images get reliable context up-front, while
                // `searchContext` stays available for follow-up drill-downs.
                // The grounding text is re-capped to a tool-aware budget that
                // reserves room for the tool schemas + appendix the framework
                // injects, so prompt + tools + response still fit the window.
                let toolGroundingContext: String
                if finalSelectedContext.isEmpty {
                    toolGroundingContext = ""
                } else {
                    let toolGroundingCharCap = TokenBudgeting.maxHybridToolGroundingCharacters(
                        maxOutputTokens: effectiveMaxOutputTokens,
                        reservedToolReplyTokens: toolBudget + 120
                    )
                    let toolGroundingTokenCap = min(
                        effectiveMaxContextTokens,
                        TokenBudgeting.estimatedTokens(forApproxCharacters: toolGroundingCharCap)
                    )
                    let toolGroundingWords = TokenBudgeting.estimatedContextWords(forTokens: toolGroundingTokenCap)
                    var grounded = TokenBudgeting.truncateToApproxWordCount(
                        finalSelectedContext,
                        maxWords: toolGroundingWords
                    )
                    if grounded.count > toolGroundingCharCap {
                        grounded = String(grounded.prefix(toolGroundingCharCap))
                    }
                    toolGroundingContext = grounded.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                debugContext("sendMessage tool-calling groundingChars=\(toolGroundingContext.count)")
                prompt = buildToolCallingPrompt(
                    for: message,
                    language: language,
                    groundingContext: toolGroundingContext
                )
            } else {
                prompt = buildPrompt(
                    for: message,
                    selectedContext: finalSelectedContext,
                    language: language,
                    maxOutputCharacters: maxOutputCharacters,
                    maxOutputTokens: effectiveMaxOutputTokens
                )
            }
            let options = GenerationOptions(temperature: temperature, maximumResponseTokens: effectiveMaxOutputTokens)
            let citations = RAGCitationFormatter.citationBlock(from: selected.topChunks, language: language)

            let assistantID = UUID()
            streamingAssistantID = assistantID
            messages.append(ChatMessage(id: assistantID, role: .assistant, content: "", citations: citations))

            var latestPartial = ""
            let responseStream = session.streamResponse(to: prompt, options: options)
            for try await snapshot in responseStream {
                let partial = String(describing: snapshot.content)
                guard !partial.isEmpty, partial != latestPartial else { continue }
                latestPartial = partial
                updateAssistantMessage(id: assistantID, content: partial, citations: citations)
            }

            let finalContent: String
            if latestPartial.isEmpty {
                let response = try await session.respond(to: prompt, options: options)
                finalContent = String(describing: response.content)
                updateAssistantMessage(id: assistantID, content: finalContent, citations: citations)
            } else {
                finalContent = latestPartial
            }

            persistMessage(role: "assistant", content: finalContent, citations: citations)
        } catch is CancellationError {
            // User pressed Stop. Preserve whatever streamed so far — losing
            // half a useful answer to a cancel click would be worse than
            // showing it with no postscript. If nothing streamed yet, drop
            // the empty placeholder so the transcript stays clean.
            if let streamingAssistantID,
               let index = messages.firstIndex(where: { $0.id == streamingAssistantID }) {
                let partial = messages[index].content
                if partial.isEmpty {
                    messages.remove(at: index)
                } else {
                    let citations = messages[index].citations
                    persistMessage(role: "assistant", content: partial, citations: citations)
                }
            }
            errorMessage = nil
        } catch {
            // A tool-calling turn can transiently fail — most notably the
            // intermittent `GenerationError -1` (context-window overflow from
            // the tool transcript). Recover by retrying the SAME question
            // WITHOUT tools: the classical grounded path builds no tool
            // transcript, so it sidesteps the failure (mirrors AIService's
            // search-path fallback). Only attempt when tools were in play and
            // we have a streaming message to write into.
            if useToolCalling, let assistantID = streamingAssistantID {
                let citations = RAGCitationFormatter.citationBlock(from: selected.topChunks, language: language)
                let isContextOverflow = Self.isContextWindowOverflow(error)
                let isToolLoopAbort = Self.isToolLoopAbort(error)
                do {
                    let recovered: String
                    if (isContextOverflow || isToolLoopAbort),
                       let toolTranscriptRecorder,
                       await toolTranscriptRecorder.hasEntries() {
                        let reason = isContextOverflow ? "context overflow" : "tool loop refusal"
                        print("ℹ️ [ChatService] tool-calling turn hit \(reason); recovering from recorded tool transcript")
                        let toolTranscriptCap = max(
                            200,
                            Int(Double(TokenBudgeting.maxContextCharacters(
                                maxOutputTokens: effectiveMaxOutputTokens,
                                contextUtilizationFactor: 1.0
                            )) * 0.55)
                        )
                        let toolTranscript = await toolTranscriptRecorder.renderedTranscript(
                            characterBudget: toolTranscriptCap
                        )
                        recovered = try await streamToolTranscriptRecovery(
                            message: message,
                            selectedContext: finalSelectedContext,
                            toolTranscript: toolTranscript,
                            language: language,
                            temperature: temperature,
                            maxOutputTokens: effectiveMaxOutputTokens,
                            assistantID: assistantID,
                            citations: citations
                        )
                    } else {
                        print("ℹ️ [ChatService] tool-calling turn failed (\(error.localizedDescription)); falling back to non-tool generation")
                        recovered = try await streamClassicalFallback(
                            message: message,
                            selectedContext: finalSelectedContext,
                            language: language,
                            temperature: temperature,
                            maxOutputTokens: effectiveMaxOutputTokens,
                            assistantID: assistantID,
                            citations: citations
                        )
                    }
                    persistMessage(role: "assistant", content: recovered, citations: citations)
                    errorMessage = nil
                    return
                } catch is CancellationError {
                    if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        let partial = messages[index].content
                        if partial.isEmpty {
                            messages.remove(at: index)
                        } else {
                            persistMessage(role: "assistant", content: partial, citations: messages[index].citations)
                        }
                    }
                    errorMessage = nil
                    return
                } catch {
                    // Fall through to the generic give-up below.
                }
            }
            let fallback = "I couldn't generate a response with the foundation model right now. Please try again."
            if let streamingAssistantID,
               let index = messages.firstIndex(where: { $0.id == streamingAssistantID }) {
                messages[index].content = fallback
                messages[index].citations = nil
            } else {
                messages.append(ChatMessage(role: .assistant, content: fallback))
            }
            persistMessage(role: "assistant", content: fallback, citations: nil)
            errorMessage = error.localizedDescription
        }
    }

    /// Non-tool recovery generation streamed into an existing assistant
    /// message. Used when a tool-calling turn throws: the classical
    /// prompt-stuffing path (pre-baked context, no tools) builds no tool
    /// transcript, so it avoids the context-window pressure behind most
    /// transient `-1` failures. Throws if it too fails (incl. cancellation).
    private func streamClassicalFallback(
        message: String,
        selectedContext: String,
        language: ModelLanguage,
        temperature: Double,
        maxOutputTokens: Int,
        assistantID: UUID,
        citations: String?
    ) async throws -> String {
        let instructions = buildInstructions(
            for: language,
            maxOutputCharacters: TokenBudgeting.estimatedOutputCharacters(forTokens: maxOutputTokens),
            useToolCalling: false
        )
        let session = LanguageModelSession(instructions: instructions)
        let maxOutputCharacters = TokenBudgeting.estimatedOutputCharacters(forTokens: maxOutputTokens)
        let prompt = buildPrompt(
            for: message,
            selectedContext: selectedContext,
            language: language,
            maxOutputCharacters: maxOutputCharacters,
            maxOutputTokens: maxOutputTokens
        )
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxOutputTokens)

        var latestPartial = ""
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            let partial = String(describing: snapshot.content)
            guard !partial.isEmpty, partial != latestPartial else { continue }
            latestPartial = partial
            updateAssistantMessage(id: assistantID, content: partial, citations: citations)
        }
        if latestPartial.isEmpty {
            let response = try await session.respond(to: prompt, options: options)
            latestPartial = String(describing: response.content)
            updateAssistantMessage(id: assistantID, content: latestPartial, citations: citations)
        }
        return latestPartial
    }

    /// Recovery path for tool-calling turns that already gathered useful
    /// tool output but later overflowed the model context window. Because
    /// Foundation Models does not expose a way to rewind an in-flight
    /// session to "the last successful tool call", we record successful
    /// tool replies on our side and replay that last known-good state in a
    /// fresh no-tool session.
    private func streamToolTranscriptRecovery(
        message: String,
        selectedContext: String,
        toolTranscript: String,
        language: ModelLanguage,
        temperature: Double,
        maxOutputTokens: Int,
        assistantID: UUID,
        citations: String?
    ) async throws -> String {
        let instructions = buildInstructions(
            for: language,
            maxOutputCharacters: TokenBudgeting.estimatedOutputCharacters(forTokens: maxOutputTokens),
            useToolCalling: false
        )
        let session = LanguageModelSession(instructions: instructions)
        let prompt = buildToolTranscriptRecoveryPrompt(
            for: message,
            selectedContext: selectedContext,
            toolTranscript: toolTranscript,
            language: language,
            maxOutputTokens: maxOutputTokens
        )
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxOutputTokens)

        var latestPartial = ""
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            let partial = String(describing: snapshot.content)
            guard !partial.isEmpty, partial != latestPartial else { continue }
            latestPartial = partial
            updateAssistantMessage(id: assistantID, content: partial, citations: citations)
        }
        if latestPartial.isEmpty {
            let response = try await session.respond(to: prompt, options: options)
            latestPartial = String(describing: response.content)
            updateAssistantMessage(id: assistantID, content: latestPartial, citations: citations)
        }
        return latestPartial
    }

    /// Pre-analyzes context in the background so send-time latency remains low.
    func preAnalyzeContext(
        contextInput: String,
        pdfURLs: [URL],
        imageURLs: [URL] = [],
        includeWebSearch: Bool,
        maxDuckDuckGoResults: Int,
        maxWikipediaResults: Int,
        maxContextTokens: Int,
        maxResponseTokens: Int,
        useDuckDuckGo: Bool = true,
        useWikipedia: Bool = true,
        useWebVision: Bool = false
    ) async {
        // Compute clamped/effective values ONCE; reused below for both the
        // cache key and the cache-hit comparison.
        let effectiveMaxDDGResults = clampedMaxDuckDuckGoResults(maxDuckDuckGoResults)
        let effectiveMaxWikiResults = clampedMaxWikipediaResults(maxWikipediaResults)
        let effectiveMaxOutputTokens = calculateEffectiveMaxOutputTokens(maxResponseTokens)
        let effectiveMaxContextTokens = calculateEffectiveContextTokens(
            requestedContextTokens: maxContextTokens,
            maxOutputTokens: effectiveMaxOutputTokens
        )

        let contextKey = makeContextKey(
            contextInput: contextInput,
            pdfURLs: pdfURLs,
            imageURLs: imageURLs,
            includeWebSearch: includeWebSearch,
            useWebVision: useWebVision,
            searchQuerySeed: "",
            clampedDuckDuckGoResults: effectiveMaxDDGResults,
            clampedWikipediaResults: effectiveMaxWikiResults
        )
        if contextKey.isEmpty {
            preAnalyzedContextKey = nil
            preAnalyzedChunks = []
            preAnalyzedMaxContextTokens = nil
            preAnalyzedMaxOutputTokens = nil
            preAnalyzedMaxDuckDuckGoResults = nil
            preAnalyzedMaxWikipediaResults = nil
            isAnalyzingContext = false
            contextAnalysisProgress = 0
            pdfAnalysisProgress = [:]
            return
        }
        if contextKey == preAnalyzedContextKey,
           effectiveMaxContextTokens == preAnalyzedMaxContextTokens,
           effectiveMaxOutputTokens == preAnalyzedMaxOutputTokens,
           effectiveMaxDDGResults == preAnalyzedMaxDuckDuckGoResults,
           effectiveMaxWikiResults == preAnalyzedMaxWikipediaResults,
           useDuckDuckGo == preAnalyzedUseDuckDuckGo,
           useWikipedia == preAnalyzedUseWikipedia,
           useWebVision == preAnalyzedUseWebVision {
            isAnalyzingContext = false
            contextAnalysisProgress = 0
            pdfAnalysisProgress = [:]
            return
        }

        isAnalyzingContext = true
        contextAnalysisProgress = 0
        debugContext("preAnalyzeContext started for pdfCount=\(pdfURLs.count) imageCount=\(imageURLs.count)")
        let chunks = await collectChunks(
            contextInput: contextInput,
            pdfURLs: pdfURLs,
            imageURLs: imageURLs,
            includeWebSearch: includeWebSearch,
            currentMessage: "",
            maxDuckDuckGoResults: effectiveMaxDDGResults,
            maxWikipediaResults: effectiveMaxWikiResults,
            maxContextTokens: effectiveMaxContextTokens,
            reportProgress: true,
            useDuckDuckGo: useDuckDuckGo,
            useWikipedia: useWikipedia,
            useWebVision: useWebVision
        )
        preAnalyzedContextKey = contextKey
        preAnalyzedChunks = chunks
        preAnalyzedMaxContextTokens = effectiveMaxContextTokens
        preAnalyzedMaxOutputTokens = effectiveMaxOutputTokens
        preAnalyzedMaxDuckDuckGoResults = effectiveMaxDDGResults
        preAnalyzedMaxWikipediaResults = effectiveMaxWikiResults
        preAnalyzedUseDuckDuckGo = useDuckDuckGo
        preAnalyzedUseWikipedia = useWikipedia
        preAnalyzedUseWebVision = useWebVision
        debugContext("preAnalyzeContext completed chunkCount=\(chunks.count)")
    }

    /// Discards an existing assistant answer (and the preceding user prompt
    /// that produced it, plus everything after) and re-runs `sendMessage`
    /// with the current settings. Use case: the user changed temperature /
    /// language / token budget and wants a fresh answer for the same prompt.
    ///
    /// - Note: anything after the target user prompt in the transcript is
    ///   discarded too — the standard "regenerate from here" semantic.
    func regenerateAssistantMessage(
        id: UUID,
        contextInput: String,
        pdfURLs: [URL],
        imageURLs: [URL] = [],
        includeWebSearch: Bool,
        maxDuckDuckGoResults: Int,
        maxWikipediaResults: Int,
        language: ModelLanguage,
        temperature: Double,
        maxResponseTokens: Int,
        maxContextTokens: Int,
        useDuckDuckGo: Bool = true,
        useWikipedia: Bool = true,
        useWebVision: Bool = false
    ) async {
        guard let assistantIndex = messages.firstIndex(where: { $0.id == id && $0.role == .assistant }) else {
            return
        }
        // Walk backwards to find the user prompt that triggered this response.
        guard let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user }) else {
            return
        }
        let userText = messages[userIndex].content

        // Drop everything from the triggering user prompt onwards — both
        // in-memory and from the persisted conversation. `sendMessage` will
        // re-append the user prompt and stream a fresh assistant response.
        messages.removeSubrange(userIndex...)
        deletePersistedTail(fromIndex: userIndex)

        // Invalidate the pre-analyzed context cache so settings changes
        // (e.g. new max-context-tokens, new sources) get re-evaluated.
        preAnalyzedContextKey = nil

        await sendMessage(
            userText,
            contextInput: contextInput,
            pdfURLs: pdfURLs,
            imageURLs: imageURLs,
            includeWebSearch: includeWebSearch,
            maxDuckDuckGoResults: maxDuckDuckGoResults,
            maxWikipediaResults: maxWikipediaResults,
            language: language,
            temperature: temperature,
            maxResponseTokens: maxResponseTokens,
            maxContextTokens: maxContextTokens,
            useDuckDuckGo: useDuckDuckGo,
            useWikipedia: useWikipedia,
            useWebVision: useWebVision
        )
    }

    /// Deletes the trailing `Message` rows from the current `Conversation`
    /// starting at the given index, mirroring how `messages` and
    /// `currentConversation.messages` are kept in lockstep by `persistMessage`.
    private func deletePersistedTail(fromIndex index: Int) {
        guard let modelContext, let conversation = currentConversation else { return }
        let persisted = conversation.messages
        guard index < persisted.count else { return }
        for message in persisted[index...] {
            modelContext.delete(message)
        }
        // Remove from the relationship array too so subsequent appends land
        // at the right offset.
        conversation.messages.removeSubrange(index...)
        conversation.updatedAt = Date()
        scheduleContextSave()
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
        pdfAnalysisProgress = [:]
        preAnalyzedContextKey = nil
        preAnalyzedChunks = []
        preAnalyzedMaxContextTokens = nil
        preAnalyzedMaxOutputTokens = nil
        preAnalyzedMaxDuckDuckGoResults = nil
        preAnalyzedMaxWikipediaResults = nil
        preAnalyzedUseDuckDuckGo = true
        preAnalyzedUseWikipedia = true
        preAnalyzedUseWebVision = false
        currentConversation = nil
        currentConversationPDFFilename = nil
        currentConversationPDFBookmark = nil
        currentConversationPDFFilenames = []
        currentConversationPDFBookmarks = []
        activePDFURLForNewConversation = nil
        activePDFURLsForNewConversation = []
    }

    /// Collects web, PDF, and image chunks from provided context.
    private func collectChunks(
        contextInput: String,
        pdfURLs: [URL],
        imageURLs: [URL] = [],
        includeWebSearch: Bool,
        currentMessage: String = "",
        language: ModelLanguage = .english,
        maxDuckDuckGoResults: Int,
        maxWikipediaResults: Int,
        maxContextTokens: Int,
        reportProgress: Bool = false,
        useDuckDuckGo: Bool = true,
        useWikipedia: Bool = true,
        useWebVision: Bool = false
    ) async -> [RAGChunk] {
        var chunks: [RAGChunk] = []
        let uniquePDFs = Array(Set(pdfURLs))
        let uniqueImages = Array(Set(imageURLs))
        if reportProgress {
            isAnalyzingContext = true
            contextAnalysisProgress = 0
            pdfAnalysisProgress = Dictionary(
                uniqueKeysWithValues: uniquePDFs.map { (Self.contextAttachmentKey(for: $0), 0.0) }
            )
        }
        defer {
            if reportProgress {
                contextAnalysisProgress = 1
                isAnalyzingContext = false
                pdfAnalysisProgress = [:]
            }
        }

        let contextURLs = extractURLs(from: contextInput)
        let effectiveMaxDDGResults = clampedMaxDuckDuckGoResults(maxDuckDuckGoResults)
        let effectiveMaxWikiResults = clampedMaxWikipediaResults(maxWikipediaResults)
        var discoveredResults: [SearchResult] = []
        // Web discovery is send-time only because it needs the current user query.
        if includeWebSearch && !currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let searchQuery = buildWebSearchQuery(
                currentMessage: currentMessage,
                contextInput: contextInput
            )
            discoveredResults = await discoverWebResults(
                for: searchQuery,
                language: language,
                maxDuckDuckGoResults: effectiveMaxDDGResults,
                maxWikipediaResults: effectiveMaxWikiResults,
                useDuckDuckGo: useDuckDuckGo,
                useWikipedia: useWikipedia
            )
        }

        var retrievedWebResults: [SearchResult] = []
        var retrievedResultURLKeys = Set<String>()
        for result in discoveredResults {
            guard let retrievedContent = result.retrievedContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !retrievedContent.isEmpty else {
                continue
            }
            let urlKey = normalizedURLString(result.url)
            if retrievedResultURLKeys.insert(urlKey).inserted {
                retrievedWebResults.append(result)
            }
        }

        let discoveredURLs = discoveredResults.map(\.url)
        let urls = deduplicatedURLs(contextURLs + discoveredURLs)
            .filter { !retrievedResultURLKeys.contains(normalizedURLString($0)) }
        let totalWorkItems = max(urls.count + uniquePDFs.count + uniqueImages.count + retrievedWebResults.count, 1)
        var completedWorkItems = 0
        let webScrapingCharacters = webScrapingCharacterBudget(forContextTokens: maxContextTokens)
        let totalMaxWebResults = effectiveMaxDDGResults + effectiveMaxWikiResults

        for result in retrievedWebResults {
            guard let retrievedContent = result.retrievedContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !retrievedContent.isEmpty else {
                continue
            }
            let chunked = await ragChunker.chunk(
                text: retrievedContent,
                source: result.title,
                maxChunkTokens: Self.webChunkMaxTokens,
                overlapTokens: Self.webChunkOverlapTokens,
                url: result.url
            )
            chunks.append(contentsOf: chunked)
            completedWorkItems += 1
            if reportProgress {
                contextAnalysisProgress = Double(completedWorkItems) / Double(totalWorkItems)
            }
        }

        if !urls.isEmpty {
            let scraped = await webScraper.scrapeMultiplePages(
                urls: urls,
                limit: min(urls.count, totalMaxWebResults),
                maxCharacters: webScrapingCharacters,
                useVision: useWebVision
            )
            for url in urls {
                guard let text = scraped[url] else { continue }
                let chunked = await ragChunker.chunk(
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
            let completedBeforePDF = completedWorkItems
            let progressKey = Self.contextAttachmentKey(for: pdfURL)
            let pageAnalyses = await ImageAnalysisService.extractPDFPageAnalyses(from: pdfURL) { [self, progressKey] completedPages, totalPages in
                guard reportProgress else { return }
                let pdfProgress = totalPages > 0 ? Double(completedPages) / Double(totalPages) : 1
                self.pdfAnalysisProgress[progressKey] = pdfProgress
                self.contextAnalysisProgress = (Double(completedBeforePDF) + pdfProgress) / Double(totalWorkItems)
            }
            debugContext("collectChunks pdf=\(pdfURL.lastPathComponent) analyzedPages=\(pageAnalyses.count)")
            for (pageIndex, analysis) in pageAnalyses.enumerated() {
                // Build the page chunk from Vision's layout-aware OCR text
                // plus classification labels. Vision sees the page's
                // *visual* layout (bounding boxes), so tables, equations,
                // and figures survive intact — no more column-major dumps
                // from PDFKit's drawing-order `page.string`.
                var pageText = analysis.recognizedText
                if !analysis.labels.isEmpty {
                    let labelText = analysis.labels
                        .map { String(format: "%@ (%.2f)", $0.label, $0.confidence) }
                        .joined(separator: ", ")
                    let labelBlock = "Page content: \(labelText)"
                    pageText = pageText.isEmpty ? labelBlock : pageText + "\n\n" + labelBlock
                }
                // Convert any whitespace-aligned tables (invoices, quotes,
                // spreadsheets exported as PDF) to Markdown pipe rows BEFORE
                // chunking. Otherwise the chunker's whitespace normalisation
                // collapses the columns and the model can't tell a price
                // from a TVA percentage on the same row.
                let tabularized = RAGChunker.convertWhitespaceAlignedTables(pageText)
                let source = "PDF: \(pdfURL.lastPathComponent) page \(pageIndex + 1)"
                let pageChunks = await Self.makePDFPageChunks(
                    text: tabularized,
                    source: source,
                    pdfPage: pageIndex + 1,
                    maxContextTokens: maxContextTokens
                )
                debugContext("collectChunks pdfPage=\(pageIndex + 1) chars=\(tabularized.count) emittedChunks=\(pageChunks.count)")
                chunks.append(contentsOf: pageChunks)
            }
            completedWorkItems += 1
            if reportProgress {
                pdfAnalysisProgress[progressKey] = 1
                contextAnalysisProgress = Double(completedWorkItems) / Double(totalWorkItems)
            }
        }

        // Images: one chunk per file containing OCR text and/or Vision classification
        // labels. We don't run the chunker — OCR output is short and a single chunk
        // keeps citation block tidy ("Image: filename.jpg").
        for imageURL in uniqueImages {
            if let chunk = await makeImageChunk(for: imageURL) {
                chunks.append(chunk)
                debugContext("collectChunks image=\(imageURL.lastPathComponent) chars=\(chunk.text.count)")
            } else {
                debugContext("collectChunks image=\(imageURL.lastPathComponent) skipped (no extractable content)")
            }
            completedWorkItems += 1
            if reportProgress {
                contextAnalysisProgress = Double(completedWorkItems) / Double(totalWorkItems)
            }
        }

        return chunks
    }

    /// Hierarchical PDF retrieval policy:
    /// 1. Prefer one whole-page chunk when the page comfortably fits inside
    ///    the current context window. This preserves sentence flow, nearby
    ///    equations, and table/explanation locality.
    /// 2. Fall back to chunking only for genuinely oversized pages.
    ///
    /// Selection/ranking still happens later in `RAGContextService`, so with
    /// many pages we effectively rank pages first and only split the rare page
    /// that would be too large to ship as one unit.
    static func makePDFPageChunks(
        text: String,
        source: String,
        pdfPage: Int,
        maxContextTokens: Int
    ) async -> [RAGChunk] {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }

        let pageCharacterBudget = max(1, maxContextTokens * TokenBudgeting.avgCharsPerToken)
        let wholePageCap = Int(Double(pageCharacterBudget) * pdfWholePageContextFraction)
        if cleanText.count <= wholePageCap {
            return [RAGChunk(source: source, text: cleanText, url: nil, pdfPage: pdfPage)]
        }

        let chunker = RAGChunker()
        return await chunker.chunk(
            text: cleanText,
            source: source,
            maxChunkTokens: pdfChunkMaxTokens,
            overlapTokens: pdfChunkOverlapTokens,
            pdfPage: pdfPage
        )
    }

    /// Runs Vision OCR + image classification on the file and packages the
    /// result as a single `RAGChunk`. Returns `nil` if neither OCR nor
    /// classification produced any usable output.
    private func makeImageChunk(for imageURL: URL) async -> RAGChunk? {
        guard let result = await ImageAnalysisService.analyze(imageAt: imageURL),
              !result.isEmpty else {
            return nil
        }

        var sections: [String] = []
        if !result.recognizedText.isEmpty {
            sections.append(result.recognizedText)
        }
        if !result.labels.isEmpty {
            let labelText = result.labels
                .map { String(format: "%@ (%.2f)", $0.label, $0.confidence) }
                .joined(separator: ", ")
            sections.append("Estimated content: \(labelText)")
        }

        return RAGChunk(
            source: "Image: \(imageURL.lastPathComponent)",
            text: sections.joined(separator: "\n\n"),
            url: nil,
            pdfPage: nil
        )
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

    private func discoverWebResults(
        for query: String,
        language: ModelLanguage,
        maxDuckDuckGoResults: Int,
        maxWikipediaResults: Int,
        useDuckDuckGo: Bool = true,
        useWikipedia: Bool = true
    ) async -> [SearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        guard useDuckDuckGo || useWikipedia else { return [] }

        do {
            let results = try await webSearchService.search(
                query: trimmedQuery,
                maxDuckDuckGoResults: clampedMaxDuckDuckGoResults(maxDuckDuckGoResults),
                maxWikipediaResults: clampedMaxWikipediaResults(maxWikipediaResults),
                language: language,
                useDuckDuckGo: useDuckDuckGo,
                useWikipedia: useWikipedia
            )

            var deduplicated: [SearchResult] = []
            var seenURLKeys = Set<String>()
            for result in results {
                guard let scheme = URL(string: result.url)?.scheme?.lowercased() else { continue }
                guard scheme == "http" || scheme == "https" else { continue }
                let urlKey = normalizedURLString(result.url)
                if seenURLKeys.insert(urlKey).inserted {
                    deduplicated.append(result)
                }
            }

            return deduplicated
        } catch {
            debugContext("discoverWebResults failed for query=\"\(trimmedQuery)\": \(error.localizedDescription)")
            return []
        }
    }

    /// Returns a stable key used to reuse pre-analyzed context.
    /// Callers pass values they have ALREADY clamped (via
    /// `clampedMaxDuckDuckGoResults` / `clampedMaxWikipediaResults`) so this
    /// helper never re-clamps. Clamping is idempotent, but doing it twice was
    /// wasteful and confusing — the cache key now reflects exactly the
    /// effective values used everywhere else in the request.
    private func makeContextKey(
        contextInput: String,
        pdfURLs: [URL],
        imageURLs: [URL] = [],
        includeWebSearch: Bool,
        useWebVision: Bool = false,
        searchQuerySeed: String,
        clampedDuckDuckGoResults: Int,
        clampedWikipediaResults: Int
    ) -> String {
        let normalizedContext = contextInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPDFPaths = Array(Set(pdfURLs.map(\.path))).sorted().joined(separator: "|")
        let normalizedImagePaths = Array(Set(imageURLs.map(\.path))).sorted().joined(separator: "|")
        let normalizedQuerySeed = includeWebSearch
            ? searchQuerySeed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : ""
        if normalizedContext.isEmpty && normalizedPDFPaths.isEmpty && normalizedImagePaths.isEmpty && normalizedQuerySeed.isEmpty {
            return ""
        }
        return "\(normalizedContext)||\(normalizedPDFPaths)||img:\(normalizedImagePaths)||web:\(includeWebSearch)||webVision:\(useWebVision)||query:\(normalizedQuerySeed)||ddg:\(clampedDuckDuckGoResults)||wiki:\(clampedWikipediaResults)"
    }

    private func clampedMaxDuckDuckGoResults(_ value: Int) -> Int {
        min(max(value, AppSettings.maxDuckDuckGoResultsRange.lowerBound), Self.maxWebContextURLCap)
    }

    private func clampedMaxWikipediaResults(_ value: Int) -> Int {
        min(max(value, AppSettings.maxWikipediaResultsRange.lowerBound), Self.maxWebContextURLCap)
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

    private func debugContext(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ChatService][Context] \(message())")
        #endif
    }

    /// Clamps requested output tokens to fit the shared 4096-token context window budget.
    private func calculateEffectiveMaxOutputTokens(
        _ requestedMaxTokens: Int,
        useToolCalling: Bool = false
    ) -> Int {
        if useToolCalling {
            return TokenBudgeting.clampedToolResponseTokens(requestedMaxTokens: requestedMaxTokens)
        }
        return TokenBudgeting.clampedOutputTokens(
            requestedMaxTokens: requestedMaxTokens,
            instructionTokens: TokenBudgeting.instructionTokens,
            promptOverheadTokens: TokenBudgeting.promptOverheadTokens,
            minContextTokens: TokenBudgeting.minContextTokens
        )
    }

    private func calculateEffectiveContextTokens(
        requestedContextTokens: Int,
        maxOutputTokens: Int
    ) -> Int {
        TokenBudgeting.clampedContextTokens(
            requestedContextTokens: requestedContextTokens,
            maxOutputTokens: maxOutputTokens,
            settingsRange: AppSettings.maxContextTokensRange,
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
                    return "Assistant: \(item.content)"
                }
                return "User: \(item.content)"
            }
            .joined(separator: "\n")

        // Communicate a CONSERVATIVE character target — well under what the
        // hard token cap actually fits for math-dense output (LaTeX commands
        // tokenise densely, so the naive chars≈tokens×3 estimate overshoots).
        // This leaves headroom for the model to wrap up and, crucially, to
        // close any equation it opened instead of being cut mid-formula.
        let conservativeOutputCharacters = max(150, Int(Double(maxOutputCharacters) * 0.65))
        let contextBlock = localizedChatContextBlock(
            from: selectedContext,
            language: language
        )

        return PromptLoader.loadPrompt(
            mode: "normal",
            feature: "chat",
            language: language,
            replacements: [
                "history": history,
                "context": selectedContext,
                "contextBlock": contextBlock,
                "question": userMessage,
                "maxOutputCharacters": "\(conservativeOutputCharacters)",
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


    private func updateAssistantMessage(id: UUID, content: String, citations: String?) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = content
        messages[index].citations = citations
    }

    /// Builds dynamic chat instructions matching the user's query language.
    /// When `useToolCalling` is true, appends an extra paragraph telling
    /// the model to call `searchContext` / `calculate` instead of
    /// answering blind. The base instructions stay the same so the model's
    /// tone and language conventions don't drift between the two modes.
    private func buildInstructions(
        for language: ModelLanguage,
        maxOutputCharacters: Int,
        useToolCalling: Bool = false,
        webSearchAvailable: Bool = false
    ) -> String {
        let base = PromptLoader.loadPrompt(
            mode: "normal",
            feature: "chat",
            variant: "instructions",
            language: language,
            replacements: [
                "maxOutputCharacters": "\(maxOutputCharacters)"
            ]
        )
            ?? fallbackChatInstructions(for: language)
        guard useToolCalling else { return base }
        return base + "\n\n" + toolCallingInstructionsAppendix(
            for: language,
            webSearchAvailable: webSearchAvailable
        )
    }

    /// Per-language paragraph appended onto the chat system instructions
    /// when tool calling is enabled. Delegates to `ToolKit` so the chat
    /// and search paths stay in lock-step on tool descriptions.
    private func toolCallingInstructionsAppendix(
        for language: ModelLanguage,
        webSearchAvailable: Bool
    ) -> String {
        ToolKit.instructionsAppendix(
            for: language,
            tone: .chat,
            webSearchAvailable: webSearchAvailable
        )
    }

    /// Builds the per-turn user prompt for the tool-calling path.
    ///
    /// Critically, this does NOT replay prior assistant answers. With a
    /// fresh `LanguageModelSession` per turn, the old approach stuffed the
    /// whole "User:/Assistant:" transcript into the prompt — and the small
    /// on-device model "continued" that transcript by echoing the previous
    /// answer verbatim (and even the trailing scaffolding) instead of
    /// answering the new question. See the multi-turn PDF-chat regression
    /// where every answer began by repeating the prior one.
    ///
    /// Instead we include only the recent *user questions* as lightweight
    /// topical context (so follow-ups like "and the osmotic pressure?"
    /// resolve), then end with a direct imperative carrying the current
    /// question.
    ///
    /// When `groundingContext` is non-empty we ALSO pre-bake the
    /// RAG-selected passages from the attached documents into the prompt —
    /// the same context the classical (prompt-stuffing) path injects. This
    /// is the reliability fix for PDF/image chat: a small on-device model
    /// frequently fails to call `searchContext` for broad questions ("how
    /// is the property obtained?"), or composes a weak lexical query that
    /// retrieves poorly. Grounding the prompt up-front guarantees the
    /// relevant passages are in front of the model for the common case,
    /// while the `searchContext` tool stays available so it can still pull
    /// more on demand for follow-ups. Net effect: tool-calling becomes a
    /// superset of the classical path's reliability, not a riskier
    /// alternative to it.
    ///
    /// Output-length and tool-usage guidance live in the session
    /// instructions (and `GenerationOptions.maximumResponseTokens`), never
    /// in the user prompt — putting them here is what leaked
    /// "(Max output: …)" into the rendered answer.
    private func buildToolCallingPrompt(
        for userMessage: String,
        language: ModelLanguage,
        groundingContext: String = ""
    ) -> String {
        // Prior user turns only (exclude the just-appended current message
        // and every assistant answer).
        let priorQuestions = messages
            .filter { $0.role == .user && $0.content != userMessage }
            .suffix(Self.historyMessageLimit)
            .map(\.content)
        return Self.assembleToolCallingPrompt(
            currentQuestion: userMessage,
            priorUserQuestions: Array(priorQuestions),
            language: language,
            groundingContext: groundingContext
        )
    }

    private func buildToolTranscriptRecoveryPrompt(
        for userMessage: String,
        selectedContext: String,
        toolTranscript: String,
        language: ModelLanguage,
        maxOutputTokens: Int
    ) -> String {
        let priorQuestions = messages
            .filter { $0.role == .user && $0.content != userMessage }
            .suffix(Self.historyMessageLimit)
            .map(\.content)
        let totalContextCharacters = TokenBudgeting.maxContextCharacters(
            maxOutputTokens: maxOutputTokens,
            contextUtilizationFactor: 1.0
        )
        let toolCap = min(toolTranscript.count, max(200, Int(Double(totalContextCharacters) * 0.55)))
        let selectedCap = max(0, totalContextCharacters - toolCap)
        let compactToolTranscript = String(toolTranscript.prefix(toolCap)).trimmingCharacters(in: .whitespacesAndNewlines)
        let compactSelectedContext = String(selectedContext.prefix(selectedCap)).trimmingCharacters(in: .whitespacesAndNewlines)

        return Self.assembleToolTranscriptRecoveryPrompt(
            currentQuestion: userMessage,
            priorUserQuestions: Array(priorQuestions),
            language: language,
            groundingContext: compactSelectedContext,
            toolTranscript: compactToolTranscript
        )
    }

    /// Pure assembly of the tool-calling prompt — separated from `messages`
    /// state so it can be regression-tested directly. Guarantees the
    /// properties that broke multi-turn PDF chat: no assistant answers are
    /// replayed (the model can't echo what it isn't shown) and no
    /// length/tool scaffolding appears (that leaked into rendered answers).
    ///
    /// `groundingContext`, when supplied, is the pre-selected document
    /// context placed BEFORE the current question so the question remains
    /// the final line of the prompt (the model ends on the thing to answer,
    /// not on continuable context). It carries no length/format scaffolding
    /// — only the passage text — so the leak-prevention contract holds.
    nonisolated static func assembleToolCallingPrompt(
        currentQuestion: String,
        priorUserQuestions: [String],
        language: ModelLanguage,
        groundingContext: String = ""
    ) -> String {
        let trimmedGrounding = groundingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGrounding = !trimmedGrounding.isEmpty

        let answerImperative: String
        let earlierLabel: String
        let groundingHeader: String
        switch language {
        case .french:
            // Grounding-aware imperative steers the model to answer from the
            // provided passages first and only reach for the tool to fill
            // gaps — cutting redundant tool round-trips when the context
            // already covers the question.
            answerImperative = hasGrounding
                ? "Appuie ta réponse sur le contexte ci-dessus. S'il ne suffit pas, appelle searchContext pour obtenir d'autres passages. Cite les sources utilisées. Réponds à la question suivante :"
                : "Réponds à la question suivante en t'appuyant sur les outils disponibles :"
            earlierLabel = "Questions précédentes de l'utilisateur (contexte) :"
            groundingHeader = "Contexte tiré des documents joints :"
        case .spanish:
            answerImperative = hasGrounding
                ? "Basa tu respuesta en el contexto anterior. Si no es suficiente, llama a searchContext para obtener más pasajes. Cita las fuentes utilizadas. Responde a la siguiente pregunta:"
                : "Responde a la siguiente pregunta apoyándote en las herramientas disponibles:"
            earlierLabel = "Preguntas anteriores del usuario (contexto):"
            groundingHeader = "Contexto de los documentos adjuntos:"
        case .english:
            answerImperative = hasGrounding
                ? "Base your answer on the context above. If it isn't enough, call searchContext for more passages. Cite the sources you use. Answer the following question:"
                : "Answer the following question using the available tools:"
            earlierLabel = "Earlier user questions (context):"
            groundingHeader = "Context from the attached documents:"
        }

        // Assemble top-to-bottom: grounding context, then prior questions,
        // then the imperative + current question. The current question is
        // always the final line regardless of which optional blocks appear.
        var sections: [String] = []
        if hasGrounding {
            sections.append("\(groundingHeader)\n\(trimmedGrounding)")
        }
        if !priorUserQuestions.isEmpty {
            let contextBlock = priorUserQuestions.map { "- \($0)" }.joined(separator: "\n")
            sections.append("\(earlierLabel)\n\(contextBlock)")
        }
        sections.append("\(answerImperative)\n\(currentQuestion)")
        return sections.joined(separator: "\n\n")
    }

    nonisolated static func assembleToolTranscriptRecoveryPrompt(
        currentQuestion: String,
        priorUserQuestions: [String],
        language: ModelLanguage,
        groundingContext: String = "",
        toolTranscript: String
    ) -> String {
        let trimmedGrounding = groundingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = toolTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGrounding = !trimmedGrounding.isEmpty

        let answerImperative: String
        let earlierLabel: String
        let groundingHeader: String
        let transcriptHeader: String
        switch language {
        case .french:
            answerImperative = "Les appels d'outils précédents ont déjà fourni le contexte utile. N'appelle plus aucun outil. Réponds maintenant à la question suivante en t'appuyant d'abord sur les résultats d'outils ci-dessus, puis sur le contexte joint si nécessaire :"
            earlierLabel = "Questions précédentes de l'utilisateur (contexte) :"
            groundingHeader = "Contexte tiré des documents joints :"
            transcriptHeader = "Résultats d'outils déjà obtenus :"
        case .spanish:
            answerImperative = "Las llamadas previas a herramientas ya aportaron el contexto útil. No llames más herramientas. Responde ahora a la siguiente pregunta apoyándote primero en los resultados de herramientas anteriores y después, si hace falta, en el contexto adjunto:"
            earlierLabel = "Preguntas anteriores del usuario (contexto):"
            groundingHeader = "Contexto de los documentos adjuntos:"
            transcriptHeader = "Resultados de herramientas ya obtenidos:"
        case .english:
            answerImperative = "The previous tool calls already gathered the useful context. Do not call any more tools. Answer the following question now using the tool results above first, then the attached-document context if needed:"
            earlierLabel = "Earlier user questions (context):"
            groundingHeader = "Context from the attached documents:"
            transcriptHeader = "Tool results already gathered:"
        }

        var sections: [String] = []
        if !trimmedTranscript.isEmpty {
            sections.append("\(transcriptHeader)\n\(trimmedTranscript)")
        }
        if hasGrounding {
            sections.append("\(groundingHeader)\n\(trimmedGrounding)")
        }
        if !priorUserQuestions.isEmpty {
            let contextBlock = priorUserQuestions.map { "- \($0)" }.joined(separator: "\n")
            sections.append("\(earlierLabel)\n\(contextBlock)")
        }
        sections.append("\(answerImperative)\n\(currentQuestion)")
        return sections.joined(separator: "\n\n")
    }

    nonisolated private static func isContextWindowOverflow(_ error: Error) -> Bool {
        if let genError = error as? LanguageModelSession.GenerationError {
            let label = String(describing: genError).lowercased()
            return label.contains("exceededcontextwindowsize")
                || label.contains("contextwindow")
        }
        let description = error.localizedDescription.lowercased()
        return description.contains("context window")
            || description.contains("exceeded model context window size")
    }

    nonisolated private static func isToolLoopAbort(_ error: Error) -> Bool {
        if error is ToolError {
            return true
        }
        let description = error.localizedDescription.lowercased()
        return description.contains("duplicate calls")
            || description.contains("calls reached for this turn")
            || description.contains("tool call limit")
    }

    private func fallbackChatInstructions(for language: ModelLanguage) -> String {
        switch language {
        case .french:
            return """
            Vous êtes un assistant de chat utile. Répondez clairement et précisément.
            Utilisez le contexte récupéré lorsqu'il est pertinent et indiquez vos incertitudes si le contexte est insuffisant.
            Si aucun contexte récupéré n'est fourni, répondez depuis vos connaissances sans vous plaindre du manque de contexte.
            Répondez dans la même langue que la question de l'utilisateur.
            """
        case .spanish:
            return """
            Usted es un asistente de chat útil. Responda con claridad y precisión.
            Utilice el contexto recuperado cuando sea pertinente e indique sus incertidumbres si el contexto es insuficiente.
            Si no se proporciona contexto recuperado, responda con su propio conocimiento y no se queje por la falta de contexto.
            Responda en el mismo idioma que la pregunta del usuario.
            """
        case .english:
            return """
            You are a helpful chat assistant. Answer the user clearly and accurately.
            Use retrieved context when relevant and mention uncertainty when context is insufficient.
            If no retrieved context is provided, answer from your own knowledge and do not complain about missing context.
            Respond in the same language as the user's latest question.
            """
        }
    }

    private func fallbackChatPrompt(
        history: String,
        selectedContext: String,
        userMessage: String,
        language: ModelLanguage,
        maxOutputCharacters: Int,
        maxOutputTokens: Int
    ) -> String {
        let contextBlock = localizedChatContextBlock(from: selectedContext, language: language)
        switch language {
        case .french:
            return """
            Conversation :
            \(history)

            \(contextBlock)Question de l'utilisateur :
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
        case .spanish:
            return """
            Conversación:
            \(history)

            \(contextBlock)Pregunta del usuario:
            \(userMessage)

            Responde de forma concisa y práctica.
            Límite de salida: \(maxOutputTokens) tokens como máximo (aproximadamente \(maxOutputCharacters) caracteres).
            Cuando sea pertinente, incluye expresiones o fórmulas matemáticas.
            Formato de salida requerido: LaTeX para expresiones matemáticas.
            Reglas de formato matemático:
            - Usa $...$ para matemáticas inline.
            - Usa \\[...\\] para bloques matemáticos.
            - Usa LaTeX simple compatible con el renderizador de la aplicación.
            - Nunca uses entornos con \\begin{.
            """
        case .english:
            return """
            Conversation:
            \(history)

            \(contextBlock)User question:
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
    }

    private func localizedChatContextBlock(from selectedContext: String, language: ModelLanguage) -> String {
        let trimmedContext = selectedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty else { return "" }
        switch language {
        case .french:
            return "Contexte récupéré :\n\(trimmedContext)\n\n"
        case .spanish:
            return "Contexto recuperado:\n\(trimmedContext)\n\n"
        case .english:
            return "Retrieved Context:\n\(trimmedContext)\n\n"
        }
    }
    private func debugLog(_ message: String) {
        #if DEBUG
        print("[ChatView] \(message)")
        #endif
    }
    /// Persists a message to the current SwiftData conversation.
    private func persistMessage(role: String, content: String, citations: String?, modelAvailabilityReason: String? = nil) {
        guard let modelContext else { return }

        // Create conversation if needed
        if currentConversation == nil {
            let (filename, bookmark) = pdfStampForNewConversation()
            let (filenames, bookmarks) = pdfStampListForNewConversation()
            let conv = Conversation(
                messages: [],
                title: role == "user" ? generateTitle(from: content) : nil,
                pdfFilename: filename,
                pdfBookmark: bookmark,
                pdfFilenames: filenames,
                pdfBookmarks: bookmarks
            )
            currentConversation = conv
            modelContext.insert(conv)
            currentConversationPDFFilename = filename
            currentConversationPDFBookmark = bookmark
            currentConversationPDFFilenames = filenames
            currentConversationPDFBookmarks = bookmarks
        }

        guard let conversation = currentConversation else { return }

        // Create and add message
        let message = Message(role: role, content: content, citations: citations, modelAvailabilityReason: modelAvailabilityReason)
        conversation.messages.append(message)
        conversation.updatedAt = Date()

        // Debug log the new message and conversation state
        #if DEBUG
        debugLog("Persisted new message with role=\(role) content=\\n \"\(content))\" \\ncitations=\"\(citations ?? "none")\"")
        debugLog("Current conversation now has \(conversation.messages.count) messages, last updated at \(conversation.updatedAt)")
        #endif

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

    /// Seeds a new conversation from a Search Assist exchange and persists it to history.
    func startConversationFromSearch(query: String, answer: String, citations: String?) {
        pendingSaveTask?.cancel()
        finalizeCurrentConversation()
        errorMessage = nil
        isResponding = false
        isAnalyzingContext = false
        contextAnalysisProgress = 0
        pdfAnalysisProgress = [:]
        preAnalyzedContextKey = nil
        preAnalyzedChunks = []
        preAnalyzedMaxContextTokens = nil
        preAnalyzedMaxOutputTokens = nil
        preAnalyzedMaxDuckDuckGoResults = nil
        preAnalyzedMaxWikipediaResults = nil
        preAnalyzedUseDuckDuckGo = true
        preAnalyzedUseWikipedia = true

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCitations = citations?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCitations = (trimmedCitations?.isEmpty ?? true) ? nil : trimmedCitations

        messages = []
        if !trimmedQuery.isEmpty {
            messages.append(ChatMessage(role: .user, content: trimmedQuery))
        }
        if !trimmedAnswer.isEmpty {
            messages.append(ChatMessage(role: .assistant, content: trimmedAnswer, citations: normalizedCitations))
        }

        guard let modelContext else { return }

        let conversation = Conversation(
            messages: [],
            title: trimmedQuery.isEmpty ? nil : generateTitle(from: trimmedQuery)
        )
        modelContext.insert(conversation)
        currentConversation = conversation

        if !trimmedQuery.isEmpty {
            conversation.messages.append(Message(role: "user", content: trimmedQuery))
        }
        if !trimmedAnswer.isEmpty {
            conversation.messages.append(Message(role: "assistant", content: trimmedAnswer, citations: normalizedCitations))
        }
        conversation.updatedAt = Date()
        _ = saveContext(modelContext)
    }

    /// Loads a previous conversation by ID and syncs it to the UI.
    func loadConversation(id: UUID) {
        guard let modelContext else { return }

        // Find the conversation
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        guard let conversation = try? modelContext.fetch(descriptor).first else { return }

        currentConversation = conversation
        currentConversationPDFFilename = conversation.pdfFilename
        currentConversationPDFBookmark = conversation.pdfBookmark
        currentConversationPDFFilenames = conversation.pdfFilenames
        currentConversationPDFBookmarks = conversation.pdfBookmarks

        // Convert SwiftData messages to ChatMessage for UI
        messages = conversation.messages
            .sorted { $0.timestamp < $1.timestamp }
            .map { ChatMessage(role: $0.role == "user" ? .user : .assistant, content: $0.content, citations: $0.citations, modelAvailabilityReason: $0.modelAvailabilityReason.flatMap { FoundationModelAvailability.Reason(stringValue: $0) }) }
    }

    /// Builds the PDF stamp for a freshly created conversation from
    /// `activePDFURLForNewConversation`. Returns `(nil, nil)` when no PDF
    /// was attached or the bookmark can't be created (e.g. file isn't
    /// reachable). Filename is *normalized* (see `Self.pdfBaseFilename`)
    /// so two drops of the same source file collapse onto one conv key.
    private func pdfStampForNewConversation() -> (String?, Data?) {
        guard let url = activePDFURLForNewConversation else { return (nil, nil) }
        let filename = Self.pdfBaseFilename(url.lastPathComponent)
        let bookmark = try? makeSecurityScopedBookmark(for: url)
        return (filename, bookmark)
    }

    /// Same as `pdfStampForNewConversation` but for the *full* set of PDFs
    /// currently in context, not just the anchor. Bookmarks that fail to
    /// build are skipped so the two parallel arrays stay aligned.
    private func pdfStampListForNewConversation() -> ([String], [Data]) {
        var names: [String] = []
        var bookmarks: [Data] = []
        for url in activePDFURLsForNewConversation {
            guard let bookmark = try? makeSecurityScopedBookmark(for: url) else { continue }
            names.append(Self.pdfBaseFilename(url.lastPathComponent))
            bookmarks.append(bookmark)
        }
        return (names, bookmarks)
    }

    /// Keeps the active conversation's persisted PDF list in sync with
    /// whatever the composer currently has attached. Called from
    /// `sendMessage` so adds/removes that happen between turns reach the
    /// store on the next message.
    private func syncCurrentConversationPDFs(with pdfURLs: [URL]) {
        guard let conv = currentConversation else { return }
        var names: [String] = []
        var bookmarks: [Data] = []
        for url in pdfURLs {
            guard let bookmark = try? makeSecurityScopedBookmark(for: url) else { continue }
            names.append(Self.pdfBaseFilename(url.lastPathComponent))
            bookmarks.append(bookmark)
        }
        // Skip the SwiftData write (and the @Published republish) when the
        // arrays haven't actually changed, so we don't trigger redundant
        // host-side reactions mid-send.
        if conv.pdfFilenames != names {
            conv.pdfFilenames = names
            currentConversationPDFFilenames = names
        }
        if conv.pdfBookmarks != bookmarks {
            conv.pdfBookmarks = bookmarks
            currentConversationPDFBookmarks = bookmarks
        }
    }

    /// Canonicalizes a PDF filename into a stable identity key:
    /// - strips one or more trailing copy suffixes (`" (N)"`) before extension
    /// - normalizes characters rewritten by dropped-file persistence (`:` and `/`)
    ///
    /// Examples:
    /// - "X.pdf" -> "X.pdf"
    /// - "X (3).pdf" -> "X.pdf"
    /// - "X (6) (2).pdf" -> "X.pdf"
    /// - "Role (F:H).pdf" -> "Role (F-H).pdf"
    static func pdfBaseFilename(_ raw: String) -> String {
        let sanitized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        guard let regex = try? NSRegularExpression(pattern: #"(?: \(\d+\))+(?=\.[^.]+$)"#) else {
            return sanitized
        }
        let ns = sanitized as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: sanitized, range: range, withTemplate: "")
    }

    private func makeSecurityScopedBookmark(for url: URL) throws -> Data {
#if os(macOS)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
#else
        return try url.bookmarkData()
#endif
    }

    /// Returns the most recently updated conversation that included a PDF
    /// with the given filename in context — whether it was the *anchor*
    /// (the legacy `pdfFilename` field, populated on the first turn) or
    /// any later addition (the `pdfFilenames` array, kept in sync by
    /// `syncCurrentConversationPDFs`). Both sides are normalized via
    /// `pdfBaseFilename` so a re-dropped "X (3).pdf" still lands on the
    /// original "X.pdf" conversation.
    ///
    /// Implementation note: we used to compose this in a single `#Predicate`
    /// with `pdfFilenames.contains(normalized)`, but SwiftData's predicate
    /// engine crashes (`EXC_BAD_ACCESS`) on `[String].contains` against a
    /// `@Model` property — that operator doesn't translate to the backing
    /// store. So this runs in two steps: cheap anchor predicate first,
    /// then an in-memory scan of the broader set as a fallback.
    func findLatestConversation(matchingPDFFilename filename: String) -> Conversation? {
        guard let modelContext else { return nil }
        let normalized = Self.pdfBaseFilename(filename)

        var anchorDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.pdfFilename == normalized },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        anchorDescriptor.fetchLimit = 1
        if let anchor = try? modelContext.fetch(anchorDescriptor).first {
            return anchor
        }

        let allDescriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let all = try? modelContext.fetch(allDescriptor) else { return nil }
        return all.first { $0.pdfFilenames.contains(normalized) }
    }

    /// Returns a conversation anchored to a PDF with the given checksum,
    /// most recently updated first. Used as a fallback when filename
    /// lookup misses (e.g. the user renamed the file).
    func findLatestConversation(matchingPDFChecksum checksum: String) -> Conversation? {
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.pdfChecksum == checksum },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Stamps the current conversation with a freshly computed checksum.
    /// Safe to call from a background hash — no-op if the conversation has
    /// already been re-opened/replaced or already carries a matching value.
    func updateCurrentConversationChecksum(_ checksum: String) {
        guard let conversation = currentConversation,
              conversation.pdfChecksum != checksum else { return }
        conversation.pdfChecksum = checksum
        scheduleContextSave()
    }
}

/// Represents a chat turn in the conversation.
struct ChatMessage: Identifiable {
    /// Distinguishes user and assistant messages.
    enum Role {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var content: String
    var citations: String?
    var modelAvailabilityReason: FoundationModelAvailability.Reason?

    init(id: UUID = UUID(), role: Role, content: String, citations: String? = nil, modelAvailabilityReason: FoundationModelAvailability.Reason? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
        self.modelAvailabilityReason = modelAvailabilityReason
    }
}
