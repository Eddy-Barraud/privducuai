//
//  ChatView.swift
//  SilicIA
//
//  Created by Eddy Barraud on 27/03/2026.
//

import SwiftUI
import SwiftData
import Combine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
import SafariServices
#endif

/// Operating mode for `ChatView`. `.full` is SilicIA's default experience;
/// `.pdfTalkme` strips features that don't make sense in PDFtalkme — the
/// attachment "+" menu (the host app controls the single PDF) and the
/// web-search settings (PDFtalkme is offline-only by design).
enum ChatViewMode {
    case full
    case pdfTalkme
}

/// Identifies which file picker the composer's `+` menu is currently
/// driving. Used to multiplex a single `.fileImporter` modifier — see
/// `ChatView.activeFilePicker`.
private enum FilePickerKind: Hashable {
    case pdf
    case image

    var allowedContentTypes: [UTType] {
        switch self {
        case .pdf: return [.pdf]
        case .image: return [.image]
        }
    }
}

/// Chat UI that sends prompts and contextual documents to `ChatService`.
struct ChatView: View {
    @Binding var sharedURLs: [String]
    @Binding var sharedPDFs: [URL]
    @Binding var sharedImages: [URL]
    @Environment(\.modelContext) private var modelContext

    let chatService: ChatService
    var mode: ChatViewMode = .full
    /// Called whenever a PDF lands in `contextSources` via this view (drop,
    /// "+" menu, shared inbox). Hosts use it to mirror the file into their
    /// own UI — e.g. PDFtalkme opens the PDF on the left pane and restores
    /// any conversation already anchored to it. Optional; ignored in
    /// SilicIA's default flow.
    var onPDFAddedToContext: ((URL) -> Void)? = nil
    /// Mirror of `onPDFAddedToContext` for removals. Fires when the user
    /// clicks the × on a PDF context row. Hosts use it to close the
    /// matching tab.
    var onPDFRemovedFromContext: ((URL) -> Void)? = nil
    /// Host-driven PDF removals. When PDFtalkme closes a tab, it sends
    /// the URL through this publisher; `ChatView` removes the matching
    /// `.pdf` context row. Decoupled from `sharedPDFs` so removals don't
    /// collide with the existing "add" inbox flow.
    var pdfRemovalRequests: AnyPublisher<URL, Never>? = nil

    /// In `.pdfTalkme` mode, web search is force-disabled regardless of
    /// the AppStorage flag — the host app is offline-only.
    private var effectiveIsWebSearchEnabled: Bool {
        mode == .pdfTalkme ? false : isWebSearchEnabled
    }
    private var effectiveUseDuckDuckGo: Bool {
        mode == .pdfTalkme ? false : settings.useDuckDuckGo
    }
    private var effectiveUseWikipedia: Bool {
        mode == .pdfTalkme ? false : settings.useWikipedia
    }

    @State private var messageInput = ""
    /// Kind of file picker currently presented. Single enum so we can use
    /// one `.fileImporter` modifier — stacking two `.fileImporter`s on the
    /// same view is a SwiftUI footgun where only the last applied modifier
    /// is wired, silently breaking the other.
    @State private var activeFilePicker: FilePickerKind? = nil
    /// In-flight model task. Held so the stop button can cancel it,
    /// which propagates `CancellationError` through every `await` inside
    /// `ChatService.sendMessage` (including the model's stream).
    @State private var submitTask: Task<Void, Never>? = nil
    /// User-attached context. Stays empty by default — the previous design
    /// always carried a phantom empty URL placeholder so the user could
    /// type into it, but that exposed an alien blank row at all times.
    /// New design: an explicit "+" menu adds rows on demand.
    @State private var contextSources: [ContextSource] = []
    /// Focus state for the newest URL row, so picking "Add URL" from the
    /// "+" menu immediately drops the keyboard caret into the new row.
    @FocusState private var focusedURLRowID: ContextSource.ID?
    @State private var preanalysisTask: Task<Void, Never>?
    /// Shared settings store (@Observable). `@Bindable` so the settings
    /// panel can derive `$settingsStore.settings.x` bindings.
    @Bindable private var settingsStore = AppSettingsStore.shared
    /// Convenience accessor over the shared store so existing `settings.x`
    /// reads and `settings.x = y` writes keep working unchanged; binding
    /// sites use `$settingsStore.settings.x`.
    private var settings: AppSettings {
        get { settingsStore.settings }
        nonmutating set { settingsStore.settings = newValue }
    }
    @State private var showSettings = false
    @State private var showHistory = false
    @FocusState private var isInputFieldFocused: Bool
    @State private var copiedMessageID: ChatMessage.ID?
    @AppStorage("chatView.isWebSearchEnabled") private var isWebSearchEnabled = false
    @State private var loggedAssistantSnapshots: [ChatMessage.ID: String] = [:]

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
        } else if showSettings {
            chatSettingsPage
        } else {
            VStack(spacing: 12) {
                chatHeaderView

                messagesView

                if let errorMessage = chatService.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Composer is a single unified container: attached
                // sources at the top, multi-line input in the middle,
                // [+ menu] and [send] in the bottom action row.
                composerView
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Whole-surface drop zone — catches anything not landing on a
            // specific row's onDrop. Row-level handlers run first and route
            // drops to a specific row when they hit one.
            .onDrop(of: [.pdf, .image, .fileURL], isTargeted: nil) { providers in
                handleAttachmentDrop(providers, rowIndex: nil)
            }
            #if canImport(UIKit)
            .overlay {
                KeyboardDismissTapOverlay(onTapOutsideTextInput: {
                    dismissKeyboard()
                })
            }
            #endif
            // Single multiplexed file importer — stacking two `.fileImporter`
            // modifiers on the same view silently breaks one of them, so we
            // drive both flows from one `activeFilePicker` enum. The kind is
            // captured into `pickerKind` before resetting state, since the
            // callback may fire after the binding has cleared.
            .fileImporter(
                isPresented: Binding(
                    get: { activeFilePicker != nil },
                    set: { isPresented in
                        if !isPresented { activeFilePicker = nil }
                    }
                ),
                allowedContentTypes: activeFilePicker?.allowedContentTypes ?? [.pdf],
                allowsMultipleSelection: true
            ) { [pickerKind = activeFilePicker] result in
                activeFilePicker = nil
                guard case .success(let urls) = result else { return }
                Task { @MainActor in
                    switch pickerKind {
                    case .pdf: appendPDFSources(urls)
                    case .image: appendImageSources(urls)
                    case .none: break
                    }
                }
            }
            .onAppear {
                chatService.modelContext = modelContext
                mergeSharedInputsIfNeeded()
            }
            .onChange(of: sharedURLs) {
                mergeSharedInputsIfNeeded()
            }
            .onChange(of: sharedPDFs) {
                mergeSharedInputsIfNeeded()
            }
            .onChange(of: sharedImages) {
                mergeSharedInputsIfNeeded()
            }
            // Host-driven PDF removal — PDFtalkme closes a tab and pipes the
            // URL through; we drop any matching `.pdf` context row by base
            // filename so a sandbox-renamed copy ("X (2).pdf") still resolves.
            .onReceive(pdfRemovalRequests ?? Empty<URL, Never>().eraseToAnyPublisher()) { url in
                let key = ChatService.pdfBaseFilename(url.lastPathComponent)
                let before = contextSources.count
                contextSources.removeAll { source in
                    if case .pdf(let existingURL?) = source.kind {
                        return ChatService.pdfBaseFilename(existingURL.lastPathComponent) == key
                    }
                    return false
                }
                if contextSources.count != before {
                    scheduleContextPreanalysis()
                }
            }
        }
    }

    /// Renders top-level chat actions. Icon-only buttons sized for the
    /// minimum 44pt tap target, with `.help` (macOS hover) and
    /// `.accessibilityLabel` (VoiceOver) on every entry.
    private var chatHeaderView: some View {
        HStack(spacing: 4) {
            headerIconButton(
                systemImage: "square.and.pencil",
                label: L.t("common.new", language: settings.language),
                action: { startOver() }
            )

            Spacer()

            headerIconButton(
                systemImage: "clock.arrow.circlepath",
                label: L.t("common.history", language: settings.language),
                action: { showHistory = true }
            )

            headerIconButton(
                systemImage: "gearshape",
                label: L.t("common.settings", language: settings.language),
                action: {
                    #if canImport(UIKit)
                    dismissKeyboard()
                    #endif
                    showSettings = true
                }
            )
        }
        .padding(.bottom, 2)
        .textSelection(.enabled)
    }

    /// Standard icon-only header button: 44pt tap target, secondary tint,
    /// hover help + VoiceOver label baked in.
    @ViewBuilder
    private func headerIconButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var chatSettingsPage: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { showSettings = false }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text(L.t("common.back", language: settings.language))
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.glass)

                Spacer()
            }
            .padding()

            ScrollView {
                chatSettingsPanel
                    .padding()
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Renders chat-specific tuning controls.
    private var chatSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L.t("chat.settings.title", language: settings.language))
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.t("chat.settings.temperature", language: settings.language))
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", settings.temperature))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Slider(value: $settingsStore.settings.temperature, in: AppSettings.temperatureRange, step: 0.05)
            }
            .disabled(!FoundationModelAvailability.check().isAvailable)
            .opacity(!FoundationModelAvailability.check().isAvailable ? 0.5 : 1.0)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.t("chat.settings.maxResponseTokens", language: settings.language))
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

                Text(L.t("chat.settings.estimatedOutput", language: settings.language, Int64(estimatedMaxOutputCharacters), Int64(estimatedMaxOutputSentences)))
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .disabled(!FoundationModelAvailability.check().isAvailable)
            .opacity(!FoundationModelAvailability.check().isAvailable ? 0.5 : 1.0)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.t("chat.settings.maxContextTokens", language: settings.language))
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

                Text(L.t("chat.settings.estimatedContext", language: settings.language, Int64(estimatedMaxContextWords)))
                .font(.caption)
                .foregroundColor(.secondary)

                if effectiveContextTokens < settings.maxContextTokens {
                    Text(L.t("chat.settings.contextCapped", language: settings.language))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
            .disabled(!FoundationModelAvailability.check().isAvailable)
            .opacity(!FoundationModelAvailability.check().isAvailable ? 0.5 : 1.0)

            if mode != .pdfTalkme {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("chat.settings.searchSources", language: settings.language))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Toggle(isOn: $settingsStore.settings.useDuckDuckGo) {
                    Text("DuckDuckGo")
                        .font(.subheadline)
                }
                if settings.useDuckDuckGo {
                    HStack {
                        Text(L.t("chat.settings.maxDDG", language: settings.language))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(settings.maxDuckDuckGoResults)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.maxDuckDuckGoResults) },
                        set: { settings.maxDuckDuckGoResults = Int($0) }
                    ), in: Double(AppSettings.maxDuckDuckGoResultsRange.lowerBound)...Double(AppSettings.maxDuckDuckGoResultsRange.upperBound), step: 1)
                }

                Toggle(isOn: $settingsStore.settings.useWikipedia) {
                    Text("Wikipedia")
                        .font(.subheadline)
                }
                if settings.useWikipedia {
                    HStack {
                        Text(L.t("chat.settings.maxWiki", language: settings.language))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(settings.maxWikipediaResults)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.maxWikipediaResults) },
                        set: { settings.maxWikipediaResults = Int($0) }
                    ), in: Double(AppSettings.maxWikipediaResultsRange.lowerBound)...Double(AppSettings.maxWikipediaResultsRange.upperBound), step: 1)
                }

                if !settings.useDuckDuckGo && !settings.useWikipedia {
                    Text(L.t("chat.settings.selectAtLeastOne", language: settings.language))
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.t("chat.settings.modelLanguage", language: settings.language))
                        .font(.subheadline)
                    Spacer()
                    Text(settings.language.rawValue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Picker("Language", selection: $settingsStore.settings.language) {
                    ForEach(ModelLanguage.allCases, id: \.self) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settingsStore.settings.useWebVision) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("chat.settings.webVisionToggle", language: settings.language))
                            .font(.subheadline)
                        Text(L.t("chat.settings.webVisionDescription", language: settings.language))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Tool-calling toggle — experimental path where the model
            // pulls context via `searchContext` and `calculate` instead
            // of receiving pre-baked RAG chunks in the prompt. Off by
            // default while behaviour matures.
            VStack(alignment: .leading, spacing: 8) {
                let isModelAvailable = FoundationModelAvailability.check().isAvailable
                Toggle(isOn: $settingsStore.settings.useToolCalling) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tool calling (experimental)")
                            .font(.subheadline)
                        Text("Lets the model search documents and call a calculator on demand instead of receiving a pre-baked context block.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(!isModelAvailable)
                .opacity(!isModelAvailable ? 0.5 : 1.0)

                if !isModelAvailable {
                    Text(FoundationModelAvailability.toolCallingNotice(language: settings.language))
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
        .glassCard(cornerRadius: 16)
    }

    /// Invisible marker pinned to the end of the transcript so we can scroll
    /// to the bottom on send / while streaming.
    private static let bottomAnchorID = "chatBottomAnchor"

    /// Whether the transcript is currently scrolled near its bottom. While
    /// true we follow a streaming reply down; once the user scrolls up to
    /// re-read, this flips false and we stop tugging them back. Starts true
    /// (a fresh/empty transcript is "at the bottom").
    @State private var isNearBottom = true

    /// How close (in points) to the bottom still counts as "near bottom".
    private static let nearBottomThreshold: CGFloat = 80

    /// Scrolls the transcript to the bottom anchor.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// Renders message history and in-progress state.
    private var messagesView: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 10) {
                if chatService.messages.isEmpty {
                    Text(L.t("chat.startConversation", language: settings.language))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

                ForEach(chatService.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(message.role == .user ? L.t("common.you", language: settings.language) : L.t("common.assistant", language: settings.language))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            if message.role == .assistant {
                                Button {
                                    PlatformClipboard.copyPlainText(message.content)
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
                                .help(L.t("common.copy", language: settings.language))
                                .accessibilityLabel(L.t("common.copy", language: settings.language))

                                Button {
                                    regenerate(messageID: message.id)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(chatService.isResponding)
                                .help(L.t("chat.message.regenerate", language: settings.language))
                                .accessibilityLabel(L.t("chat.message.regenerate", language: settings.language))
                            }
                        }
                        renderedMessageContent(message)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    // User turns get accent-tinted glass; assistant turns
                    // get the neutral glass material. Both refract the
                    // scroll content behind them in the Liquid Glass style.
                    .modifier(MessageBubbleGlass(isUser: message.role == .user))
                    .frame(
                        maxWidth: .infinity,
                        alignment: message.role == .assistant ? .leading : .trailing
                    )
                }

                if chatService.isResponding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L.t("common.thinking", language: settings.language))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }

                // Bottom anchor — scroll target for send / streaming.
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Restore the pre-glass system text-background fill + corner radius
        // so the messages area reads as a distinct light surface, matching
        // the look users preferred before the Liquid Glass migration.
        .background(PlatformColors.textBackground)
        .cornerRadius(10)
        // Track how close to the bottom the user is, so we don't yank them
        // back down while they're scrolling up to re-read.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let bottomEdge = geometry.contentOffset.y + geometry.containerSize.height
            return bottomEdge >= geometry.contentSize.height - Self.nearBottomThreshold
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
        // Sending a message is the user's own action → always scroll to it.
        .onChange(of: chatService.messages.count) {
            scrollToBottom(proxy)
            isNearBottom = true
        }
        // While the reply streams, only follow it down if the user hasn't
        // scrolled up — otherwise leave their position alone.
        .onChange(of: chatService.messages.last?.content) {
            if isNearBottom {
                scrollToBottom(proxy)
            }
        }
        }
    }

    /// Renders assistant replies with LaTeX-aware text and keeps plaintext for user turns.
    @ViewBuilder
    private func renderedMessageContent(_ message: ChatMessage) -> some View {
        if message.role == .assistant {
            VStack(alignment: .leading, spacing: 8) {
                if let reason = message.modelAvailabilityReason {
                    ModelAvailabilityNotice(reason: reason, language: settings.language, drawBackground: false)
                } else {
                    StreamingLaTeXText(text: message.content, isStreaming: isStreamingAssistantMessage(message))

                    if let citations = message.citations,
                       !citations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()

                        if let attributedCitations = try? AttributedString(markdown: citations) {
                            #if canImport(UIKit)
                            citationLinksView(from: citations)
                            #else
                            Text(attributedCitations)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .tint(.accentColor)
                            #endif
                        } else {
                            Text(citations)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        } else {
            Text(message.content)
        }
    }

    private func isStreamingAssistantMessage(_ message: ChatMessage) -> Bool {
        guard chatService.isResponding, message.role == .assistant else { return false }
        return chatService.messages.last?.id == message.id
    }
    

    /// Unified composer: attached-source list, primary multi-line input,
    /// and bottom action row (`+` add-menu on the left, circular send on
    /// the right) all live in one rounded, stroked container so the
    /// input surface reads as a single focal point — the layout pattern
    /// Claude / ChatGPT / Gemini converged on.
    private var composerView: some View {
        let isInputEmpty = messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isResponding = chatService.isResponding
        let isAnalyzingContext = chatService.isAnalyzingContext
        // Send button is disabled only when there's nothing to send AND
        // the model isn't responding. While responding, the button is
        // replaced by a Stop button entirely (handled below).
        let isSendDisabled = isInputEmpty || isAnalyzingContext

        return VStack(alignment: .leading, spacing: 8) {
            // Attached-source list. Hidden when nothing has been added.
            // The web-search toggle surfaces as a chip when enabled, so
            // its state is visible alongside the actual sources.
            if isWebSearchEnabled || !contextSources.isEmpty {
                VStack(spacing: 6) {
                    if isWebSearchEnabled {
                        webSearchChip
                    }
                    ForEach(Array(contextSources.enumerated()), id: \.element.id) { index, source in
                        contextRow(source: source, at: index)
                    }
                }
            }

            // Primary text input. Same pattern as SearchView's search
            // field: axis:.vertical with line-limit growth, .submitLabel
            // for the iOS keyboard's affordance, and .onSubmit hooked to
            // the send action. SearchView proves this combination fires
            // .onSubmit on macOS Return AND iOS keyboard-Send without
            // platform-specific glue — no NSTextView wrapper needed.
            TextField(L.t("chat.composer.placeholder", language: settings.language), text: $messageInput, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isInputFieldFocused)
                .submitLabel(.send)
                #if canImport(UIKit)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                #endif
                .onSubmit {
                    submitMessage()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

            // Bottom action row: + menu (leading), send/stop control
            // (trailing). Per-PDF preanalysis progress renders directly
            // under each PDF row instead of in the composer footer.
            HStack(spacing: 8) {
                if mode != .pdfTalkme {
                    attachmentMenu
                }

                Spacer()

                // Swap send → stop while the model is generating, so
                // the user can interrupt long answers (or runaway tool
                // loops) without waiting it out.
                if isResponding {
                    Button(action: cancelCurrentResponse) {
                        Image(systemName: "stop.circle.fill")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.red)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L.t("chat.composer.stop", language: settings.language))
                    .accessibilityLabel(L.t("chat.composer.stop", language: settings.language))
                } else {
                    Button(action: submitMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(isSendDisabled ? Color.secondary : Color.accentColor)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSendDisabled)
                    .help(L.t("chat.composer.send", language: settings.language))
                    .accessibilityLabel(L.t("chat.composer.send", language: settings.language))
                }
            }
        }
        .padding(8)
        // Liquid Glass input island. Replaces the former solid fill +
        // hairline stroke; the system material supplies the border,
        // shadow, and light/dark adaptation, and refracts the message
        // list scrolling behind it.
        .glassCard(cornerRadius: 16)
        // Treat the whole composer surface as a tap target for focusing
        // the input — previously only the placeholder text itself
        // received taps, which gave a single-line-tall hit area in an
        // otherwise spacious container. `.contentShape(Rectangle())`
        // makes the rounded background hit-testable; the tap gesture
        // promotes the text field to first responder. Buttons inside
        // (attachment menu, send/stop) still consume their own taps
        // first because SwiftUI prioritises Button.action gestures
        // above ancestor `.onTapGesture`.
        .contentShape(Rectangle())
        .onTapGesture {
            isInputFieldFocused = true
        }
    }

    /// Single "+" menu that gathers every attach-or-toggle action that
    /// used to be three separate buttons in the legacy context-box
    /// header. Web-search toggle is the last item with a checkmark so
    /// its state is visible inside the menu too.
    private var attachmentMenu: some View {
        Menu {
            Button {
                appendNewURLRow()
            } label: {
                Label(L.t("chat.context.addURL", language: settings.language), systemImage: "link")
            }
            Button {
                activeFilePicker = .pdf
            } label: {
                Label(L.t("chat.context.addPDF", language: settings.language), systemImage: "doc.richtext")
            }
            Button {
                activeFilePicker = .image
            } label: {
                Label(L.t("chat.context.addImage", language: settings.language), systemImage: "photo")
            }
            Divider()
            Toggle(isOn: $isWebSearchEnabled) {
                Label(L.t("chat.context.web", language: settings.language), systemImage: "globe")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .resizable()
                .frame(width: 28, height: 28)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(L.t("chat.context.addAttachment", language: settings.language))
        .accessibilityLabel(L.t("chat.context.addAttachment", language: settings.language))
    }

    /// Compact pill showing that web search is currently enabled. Tap
    /// to disable — mirrors the "delete chip" gesture on attached
    /// sources.
    private var webSearchChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(Color.accentColor)
            Text(L.t("chat.context.web", language: settings.language))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                isWebSearchEnabled = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("common.delete", language: settings.language))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .subtleAccentChip(cornerRadius: 10)
    }

    /// Appends a fresh empty URL row to `contextSources` and focuses
    /// its text field so the user can start typing immediately.
    private func appendNewURLRow() {
        let new = ContextSource(kind: .url(text: ""))
        contextSources.append(new)
        // Defer focus to next runloop so the row is actually in the view tree.
        DispatchQueue.main.async {
            focusedURLRowID = new.id
        }
    }

    /// Renders a single attached source as a compact chip-like row.
    /// URL rows stay editable inline; PDF and image rows are read-only
    /// filename labels with a trailing delete button.
    private func contextRow(source: ContextSource, at index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: source.kindSymbol)
                .foregroundColor(source.kindColor)
            switch source.kind {
            case .url:
                TextField(
                    L.t("chat.context.urlPlaceholder.other", language: settings.language),
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
                .textFieldStyle(.plain)
                .focused($focusedURLRowID, equals: source.id)
            case .pdf:
                if case .pdf(let url) = source.kind {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(url?.lastPathComponent ?? "PDF")
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                        if let progress = pdfAnalysisProgress(for: url) {
                            ProgressView(value: progress)
                                .controlSize(.small)
                        }
                    }
                    Spacer()
                }
            case .image:
                if case .image(let url) = source.kind {
                    Text(url?.lastPathComponent ?? L.t("chat.context.image.attached", language: settings.language))
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            Button {
                let removed = contextSources.remove(at: index)
                if case .pdf(let url?) = removed.kind {
                    onPDFRemovedFromContext?(url)
                }
                scheduleContextPreanalysis()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("common.delete", language: settings.language))
        }
        .padding(8)
        .subtleTile(cornerRadius: 10)
        .onDrop(of: [.pdf, .image, .fileURL], isTargeted: nil) { providers in
            handleAttachmentDrop(providers, rowIndex: index)
        }
    }

    /// Cancels the in-flight model task. Triggered by the Stop button that
    /// replaces the send arrow while `chatService.isResponding` is true.
    /// Propagates `CancellationError` through every `await` in
    /// `ChatService.sendMessage`, which handles it gracefully (keeps any
    /// partial streamed content, doesn't surface a generic error).
    private func cancelCurrentResponse() {
        submitTask?.cancel()
        submitTask = nil
    }

    /// Validates and dispatches the current text input to the chat service.
    private func submitMessage() {
        #if canImport(UIKit)
        dismissKeyboard()
        #endif

        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !chatService.isAnalyzingContext else { return }

        // Drop any "+ → Add URL" rows the user opened but never filled.
        compactEmptyURLSources()

        let message = trimmed
        #if DEBUG
        let selectedPDFs = currentSelectedPDFs()
        debugSync("submitMessage sending pdfCount=\(selectedPDFs.count) pdfs=\(selectedPDFs.map(\.lastPathComponent)) imageCount=\(currentSelectedImages().count)")
        #endif
        messageInput = ""

        // Capture the task so the Stop button can cancel it. Replaces
        // any previously-running task (shouldn't happen since the UI
        // hides the send button while responding, but guard anyway).
        submitTask?.cancel()
        submitTask = Task {
            await chatService.sendMessage(
                message,
                contextInput: currentContextInputString(),
                pdfURLs: currentSelectedPDFs(),
                imageURLs: currentSelectedImages(),
                includeWebSearch: effectiveIsWebSearchEnabled,
                maxDuckDuckGoResults: settings.maxDuckDuckGoResults,
                maxWikipediaResults: settings.maxWikipediaResults,
                language: settings.language,
                temperature: settings.temperature,
                maxResponseTokens: settings.maxResponseTokens,
                maxContextTokens: settings.maxContextTokens,
                useDuckDuckGo: effectiveUseDuckDuckGo,
                useWikipedia: effectiveUseWikipedia,
                useToolCalling: settings.useToolCalling,
                useWebVision: settings.useWebVision
            )
        }
    }

    /// Joins all URL-row text values into the newline-separated
    /// `contextInput` string consumed by `ChatService`. Shared by
    /// `submitMessage`, the regenerate button, and `scheduleContextPreanalysis`.
    private func currentContextInputString() -> String {
        contextSources
            .compactMap { source -> String? in
                guard case .url(let text) = source.kind else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
    }

    /// Returns the persistent file URLs of all PDF context rows.
    private func currentSelectedPDFs() -> [URL] {
        deduplicatedPDFURLsByBaseName(contextSources.compactMap { source -> URL? in
            guard case .pdf(let url) = source.kind else { return nil }
            return url
        })
    }

    /// Deduplicates PDFs by normalized base filename while preserving order.
    /// Keeps sync idempotent when the same logical PDF arrives through
    /// different sandbox paths or persisted copy names.
    private func deduplicatedPDFURLsByBaseName(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = ChatService.pdfBaseFilename(url.lastPathComponent)
            if seen.insert(key).inserted {
                result.append(url)
            } else {
                debugSync("Dedup suppressed duplicate PDF key=\(key) url=\(url.path)")
            }
        }
        return result
    }

    /// Returns the persistent file URLs of all image context rows.
    private func currentSelectedImages() -> [URL] {
        contextSources.compactMap { source -> URL? in
            guard case .image(let url) = source.kind else { return nil }
            return url
        }
    }

    /// Re-issues the user prompt that produced the given assistant message,
    /// using the current settings.
    private func regenerate(messageID: ChatMessage.ID) {
        Task {
            await chatService.regenerateAssistantMessage(
                id: messageID,
                contextInput: currentContextInputString(),
                pdfURLs: currentSelectedPDFs(),
                imageURLs: currentSelectedImages(),
                includeWebSearch: effectiveIsWebSearchEnabled,
                maxDuckDuckGoResults: settings.maxDuckDuckGoResults,
                maxWikipediaResults: settings.maxWikipediaResults,
                language: settings.language,
                temperature: settings.temperature,
                maxResponseTokens: settings.maxResponseTokens,
                maxContextTokens: settings.maxContextTokens,
                useDuckDuckGo: effectiveUseDuckDuckGo,
                useWikipedia: effectiveUseWikipedia,
                useWebVision: settings.useWebVision
            )
        }
    }

    /// Image file extensions accepted by the drag-and-drop / file picker pipeline.
    private static let imageFileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp"
    ]

    /// Handles dropped file providers — PDFs and images. Other types are
    /// silently ignored. Each PDF/image is persisted to its dedicated temp
    /// store and added to `contextSources`.
    private func handleAttachmentDrop(_ providers: [NSItemProvider], rowIndex: Int? = nil) -> Bool {
        debugDrop("Received drop with \(providers.count) providers at rowIndex=\(String(describing: rowIndex))")
        for (index, provider) in providers.enumerated() {
            debugDrop("Provider[\(index)] registeredTypeIdentifiers=\(provider.registeredTypeIdentifiers)")
        }
        let acceptedProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        debugDrop("Filtered \(acceptedProviders.count) accepted providers")
        guard !acceptedProviders.isEmpty else {
            debugDrop("Drop ignored: no provider conforms to public.pdf, public.image, or public.file-url")
            return false
        }

        for (index, provider) in acceptedProviders.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                loadPDFFromProvider(provider, index: index, rowIndex: rowIndex)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                loadImageFromProvider(provider, index: index, rowIndex: rowIndex)
                continue
            }
            loadFileURLFromProvider(provider, index: index, rowIndex: rowIndex)
        }

        return true
    }

    private func loadPDFFromProvider(_ provider: NSItemProvider, index: Int, rowIndex: Int?) {
        debugDrop("Provider[\(index)] loading file representation for public.pdf")
        provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
            if let error {
                debugDrop("Provider[\(index)] loadFileRepresentation error: \(error.localizedDescription)")
            }
            guard let url else {
                debugDrop("Provider[\(index)] loadFileRepresentation returned nil URL")
                return
            }
            let preferredName = provider.suggestedName
            guard let persistentURL = persistDroppedPDF(url, preferredFileName: preferredName) else { return }
            Task { @MainActor in
                insertPDFSource(persistentURL, at: rowIndex)
            }
        }
    }

    private func loadImageFromProvider(_ provider: NSItemProvider, index: Int, rowIndex: Int?) {
        debugDrop("Provider[\(index)] loading file representation for public.image")
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
            if let error {
                debugDrop("Provider[\(index)] loadFileRepresentation error: \(error.localizedDescription)")
            }
            guard let url else {
                debugDrop("Provider[\(index)] image loadFileRepresentation returned nil URL")
                return
            }
            let preferredName = provider.suggestedName ?? url.lastPathComponent
            guard let persistentURL = persistDroppedImage(url, preferredFileName: preferredName) else { return }
            Task { @MainActor in
                insertImageSource(persistentURL, at: rowIndex)
            }
        }
    }

    private func loadFileURLFromProvider(_ provider: NSItemProvider, index: Int, rowIndex: Int?) {
        debugDrop("Provider[\(index)] loading item for public.file-url")
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            if let error {
                debugDrop("Provider[\(index)] loadItem error: \(error.localizedDescription)")
            }
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
            guard let fileURL else {
                debugDrop("Provider[\(index)] rejected dropped item; resolvedURL=nil")
                return
            }
            let ext = fileURL.pathExtension.lowercased()
            if ext == "pdf" {
                guard let persistentURL = persistDroppedPDF(fileURL) else { return }
                Task { @MainActor in
                    insertPDFSource(persistentURL, at: rowIndex)
                }
            } else if Self.imageFileExtensions.contains(ext) {
                guard let persistentURL = persistDroppedImage(fileURL) else { return }
                Task { @MainActor in
                    insertImageSource(persistentURL, at: rowIndex)
                }
            } else {
                debugDrop("Provider[\(index)] unsupported extension: \(ext)")
            }
        }
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

    /// Copies dropped image to a stable temporary location so it remains readable for Vision analysis.
    private func persistDroppedImage(_ sourceURL: URL, preferredFileName: String? = nil) -> URL? {
        let persistentURL = DroppedImageStore.persist(sourceURL, preferredFileName: preferredFileName)
        if let persistentURL {
            debugDrop("Copied dropped image from \(sourceURL.path) to \(persistentURL.path)")
        } else {
            debugDrop("Failed to persist dropped image from \(sourceURL.path)")
        }
        return persistentURL
    }

    /// Adds incoming shared URLs/PDFs/images to context rows once.
    private func mergeSharedInputsIfNeeded() {
        debugSync("mergeSharedInputsIfNeeded sharedURLs=\(sharedURLs.count) sharedPDFs=\(sharedPDFs.count) sharedImages=\(sharedImages.count)")
        let incomingURLs = sharedURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let incomingPDFs = deduplicatedPDFURLsByBaseName(
            sharedPDFs
                .filter { $0.pathExtension.lowercased() == "pdf" }
                .compactMap { sourceURL in
                    persistDroppedPDF(sourceURL, preferredFileName: sourceURL.lastPathComponent) ?? sourceURL
                }
        )
        let incomingImages = sharedImages
            .filter { Self.imageFileExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { sourceURL in
                persistDroppedImage(sourceURL, preferredFileName: sourceURL.lastPathComponent) ?? sourceURL
            }
        debugSync("mergeSharedInputs incoming urls=\(incomingURLs.count) pdfs=\(incomingPDFs.map(\.lastPathComponent)) images=\(incomingImages.count)")
        guard !incomingURLs.isEmpty || !incomingPDFs.isEmpty || !incomingImages.isEmpty else { return }

        // If a conversation is already loaded and anchored to one of the
        // incoming PDFs, don't reset — just add the file(s) to context. This
        // lets PDFtalkme (and SilicIA history flows) re-open a conversation
        // and attach its PDF without clobbering the restored messages.
        // Compare via `pdfBaseFilename` so "X.pdf" matches a freshly
        // re-persisted "X (2).pdf" copy from `DroppedPDFStore`.
        let activeFilename = chatService.currentConversationPDFFilename
        let matchesActiveConversation = activeFilename.map { name in
            let normalizedActive = ChatService.pdfBaseFilename(name)
            return incomingPDFs.contains {
                ChatService.pdfBaseFilename($0.lastPathComponent) == normalizedActive
            }
        } ?? false
        debugSync("mergeSharedInputs activePDF=\(activeFilename ?? "nil") matchesActiveConversation=\(matchesActiveConversation)")

        if matchesActiveConversation {
            debugSync("mergeSharedInputs action=attach")
            attachSharedInputsToCurrentConversation(urls: incomingURLs, pdfs: incomingPDFs, images: incomingImages)
        } else {
            debugSync("mergeSharedInputs action=startNew")
            startNewConversationFromSharedInputs(urls: incomingURLs, pdfs: incomingPDFs, images: incomingImages)
        }
        sharedURLs.removeAll()
        sharedPDFs.removeAll()
        sharedImages.removeAll()
        scheduleContextPreanalysis()
    }

    /// Adds the incoming attachments to the existing conversation's context
    /// rows without resetting the chat. Used when reopening a PDF whose
    /// conversation is already loaded — we want the PDF available as RAG
    /// context for the next message, but the prior turns must stay.
    private func attachSharedInputsToCurrentConversation(urls: [String], pdfs: [URL], images: [URL]) {
        for u in urls where !contextSources.contains(where: {
            if case .url(let text) = $0.kind { return text == u } else { return false }
        }) {
            contextSources.append(ContextSource(kind: .url(text: u)))
        }
        for pdf in pdfs { insertPDFSource(pdf, at: nil) }
        for image in images where !contextSources.contains(where: {
            if case .image(let existing) = $0.kind { return existing == image } else { return false }
        }) {
            contextSources.append(ContextSource(kind: .image(url: image)))
        }
    }

    private func startNewConversationFromSharedInputs(urls: [String], pdfs: [URL], images: [URL] = []) {
        preanalysisTask?.cancel()
        messageInput = ""
        chatService.resetConversation()

        let uniquePDFs = deduplicatedPDFURLsByBaseName(pdfs)
        debugSync("startNewConversationFromSharedInputs urls=\(urls.count) pdfs=\(uniquePDFs.map(\.lastPathComponent)) images=\(images.count)")
        var newSources: [ContextSource] = urls.map { ContextSource(kind: .url(text: $0)) }
        newSources.append(contentsOf: uniquePDFs.map { ContextSource(kind: .pdf(url: $0)) })
        newSources.append(contentsOf: images.map { ContextSource(kind: .image(url: $0)) })
        contextSources = newSources
    }

    /// Inserts a PDF source while keeping URL placeholder behavior.
    private func insertPDFSource(_ url: URL, at rowIndex: Int?) {
        guard url.pathExtension.lowercased() == "pdf" else {
            debugDrop("Ignoring non-PDF URL during insert: \(url.path)")
            return
        }
        // Dedup by *base* filename so re-dropping the same source file
        // (which `DroppedPDFStore` re-persists as "X (2).pdf", "X (3).pdf"…)
        // doesn't add a phantom second context row.
        let incomingKey = ChatService.pdfBaseFilename(url.lastPathComponent)
        guard !contextSources.contains(where: { source in
            if case .pdf(let existingURL) = source.kind, let existingURL {
                return ChatService.pdfBaseFilename(existingURL.lastPathComponent) == incomingKey
            }
            return false
        }) else {
            debugDrop("Ignoring duplicate PDF context URL: \(url.path)")
            debugSync("insertPDFSource suppressed duplicate key=\(incomingKey) url=\(url.path)")
            return
        }

        if let rowIndex, contextSources.indices.contains(rowIndex) {
            contextSources[rowIndex].kind = .pdf(url: url)
            debugDrop("Inserted dropped PDF into existing context row \(rowIndex): \(url.lastPathComponent)")
        } else {
            contextSources.append(ContextSource(kind: .pdf(url: url)))
            debugDrop("Appended dropped PDF as new context row: \(url.lastPathComponent)")
        }
        onPDFAddedToContext?(url)
        debugSync("insertPDFSource accepted key=\(incomingKey) rowIndex=\(String(describing: rowIndex)) contextPDFCount=\(currentSelectedPDFs().count)")
        scheduleContextPreanalysis()
    }

    /// Inserts an image source while keeping URL placeholder behavior.
    private func insertImageSource(_ url: URL, at rowIndex: Int?) {
        guard Self.imageFileExtensions.contains(url.pathExtension.lowercased()) else {
            debugDrop("Ignoring non-image URL during insert: \(url.path)")
            return
        }
        guard !contextSources.contains(where: { source in
            if case .image(let existingURL) = source.kind {
                return existingURL == url
            }
            return false
        }) else {
            debugDrop("Ignoring duplicate image context URL: \(url.path)")
            return
        }

        if let rowIndex, contextSources.indices.contains(rowIndex) {
            contextSources[rowIndex].kind = .image(url: url)
            debugDrop("Inserted dropped image into existing context row \(rowIndex): \(url.lastPathComponent)")
        } else {
            contextSources.append(ContextSource(kind: .image(url: url)))
            debugDrop("Appended dropped image as new context row: \(url.lastPathComponent)")
        }
        scheduleContextPreanalysis()
    }

    private func debugDrop(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ChatView][PDFDrop] \(message())")
        #endif
    }

    private func debugSync(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ChatView][PDFSync] \(message())")
        #endif
    }

    #if canImport(UIKit)
    @ViewBuilder
    private func citationLinksView(from text: String) -> some View {
        let links = extractCitationLinks(from: text)

        if links.isEmpty {
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                    Button(action: {
                        openURLInSafari(link.url)
                    }) {
                        Text("\(index + 1). \(displayURL(link.url))")
                            .font(.footnote)
                            .foregroundColor(.accentColor)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func extractCitationLinks(from text: String) -> [CitationLink] {
        var extracted: [CitationLink] = []

        if let markdownRegex = try? NSRegularExpression(pattern: #"\[[^\]]+\]\((https?://[^\s)]+)\)"#) {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = markdownRegex.matches(in: text, range: nsRange)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else {
                    continue
                }
                let candidate = String(text[range])
                if let url = normalizedURL(from: candidate) {
                    extracted.append(CitationLink(url: url))
                }
            }
        }

        if extracted.isEmpty,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, range: nsRange)
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                let candidate = String(text[range])
                if let url = normalizedURL(from: candidate) {
                    extracted.append(CitationLink(url: url))
                }
            }
        }

        var seen = Set<String>()
        return extracted.filter { link in
            let key = link.url.absoluteString
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private func normalizedURL(from candidate: String) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}"))
        return URL(string: cleaned)
    }

    private func displayURL(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    private func openURLInSafari(_ url: URL) {
        DispatchQueue.main.async {
            let safariViewController = SFSafariViewController(url: url)
            safariViewController.modalPresentationStyle = .fullScreen

            if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(safariViewController, animated: true, completion: nil)
            } else if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }

    private struct CitationLink: Identifiable {
        let id = UUID()
        let url: URL
    }
    #endif

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

    /// Appends multiple images.
    private func appendImageSources(_ urls: [URL]) {
        for url in urls {
            let persisted = persistDroppedImage(url, preferredFileName: url.lastPathComponent) ?? url
            insertImageSource(persisted, at: nil)
        }
    }

    /// Trims trailing empty URL rows that the user dropped via the
    /// "+ → Add URL" affordance without typing anything. Called before
    /// submit so the model never sees phantom blank URLs in context.
    private func compactEmptyURLSources() {
        contextSources.removeAll { source in
            if case .url(let text) = source.kind {
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }

    /// Triggers background context analysis shortly after edits.
    private func scheduleContextPreanalysis() {
        preanalysisTask?.cancel()
        let contextInput = currentContextInputString()
        let selectedPDFs = currentSelectedPDFs()
        let selectedImages = currentSelectedImages()
        preanalysisTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await chatService.preAnalyzeContext(
                contextInput: contextInput,
                pdfURLs: selectedPDFs,
                imageURLs: selectedImages,
                includeWebSearch: effectiveIsWebSearchEnabled,
                maxDuckDuckGoResults: settings.maxDuckDuckGoResults,
                maxWikipediaResults: settings.maxWikipediaResults,
                maxContextTokens: settings.maxContextTokens,
                maxResponseTokens: settings.maxResponseTokens,
                useDuckDuckGo: effectiveUseDuckDuckGo,
                useWikipedia: effectiveUseWikipedia,
                useWebVision: settings.useWebVision
            )
        }
    }

    /// Resets transcript and local context inputs to start a new conversation.
    private func startOver() {
        preanalysisTask?.cancel()
        messageInput = ""
        contextSources = []
        sharedURLs.removeAll()
        sharedPDFs.removeAll()
        sharedImages.removeAll()
        chatService.resetConversation()
        _ = DroppedPDFStore.clearAll()
        _ = DroppedImageStore.clearAll()
    }

    private func pdfAnalysisProgress(for url: URL?) -> Double? {
        guard chatService.isAnalyzingContext, let url else { return nil }
        return chatService.pdfAnalysisProgress[ChatService.contextAttachmentKey(for: url)]
    }
}


private struct ContextSource: Identifiable {
    enum Kind {
        case url(text: String)
        case pdf(url: URL?)
        case image(url: URL?)
    }

    let id = UUID()
    var kind: Kind

    var kindSymbol: String {
        switch kind {
        case .url: return "link"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        }
    }

    var kindColor: Color {
        switch kind {
        case .url: return .blue
        case .pdf: return .red
        case .image: return .orange
        }
    }
}
