//
//  SearchView.swift
//  SilicIA
//
//  Created by Claude on 23/03/2026.
//

import SwiftUI
import LaTeXSwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
import SafariServices
#endif

/// Main search experience that fetches web results and generates AI summaries.
struct SearchView: View {
    private static let aiSummaryOverfetchResults = 3
    private static let firstGuessTokenCap = 220
    private static let deepSearchDerivedQueryCount = 3
    @Environment(\.colorScheme) private var colorScheme
    let initialQuery: String?
    let onInitialQueryHandled: (() -> Void)?
    let chatService: ChatService
    let onOfflineQuery: ((String) -> Void)?

    @StateObject private var searchService = WebSearchService()
    @StateObject private var aiService = AIService()

    @State private var searchQuery = ""
    @State private var searchResults: [SearchResult] = []
    @State private var showingSummary = false
    @State private var isNoAIMode = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFieldFocused: Bool

    // Settings
    @State private var settings = AppSettings.load()
    @State private var showSettings = false
    @State private var activeGenerationProfile: AIService.GenerationProfile = .fast

    // Generation timer
    @State private var summaryStartTime: Date? = nil
    @State private var summaryElapsedSeconds: Double? = nil
    @State private var firstGuessElapsedSeconds: Double? = nil
    @State private var firstGuessText = ""
    @State private var isGeneratingFirstGuess = false
    @State private var activeSearchRequestID = UUID()
    @State private var didCopySummary = false

    init(
        initialQuery: String? = nil,
        onInitialQueryHandled: (() -> Void)? = nil,
        chatService: ChatService,
        onOfflineQuery: ((String) -> Void)? = nil
    ) {
        self.initialQuery = initialQuery
        self.onInitialQueryHandled = onInitialQueryHandled
        self.chatService = chatService
        self.onOfflineQuery = onOfflineQuery
    }
    
    private var windowBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

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
        return Color(UIColor.tertiarySystemBackground)
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

    private var defaultScrapingCharactersFromContextTokens: Int {
        max(TokenBudgeting.estimatedContextCharacters(forTokens: effectiveContextTokens) * 2, 1500)
    }

    /// Lays out header, search controls, and context-sensitive body content.
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Settings panel available in every search state
            if showSettings {
                settingsPanel
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Content
            if searchService.isSearching {
                loadingView
            } else if !searchResults.isEmpty {
                resultsView
            } else if searchQuery.isEmpty {
                welcomeView
            } else {
                emptyStateView
            }
            // Search Bar
            searchBarView
        }
        .background(windowBackgroundColor)
        .animation(.easeInOut, value: showSettings)
        .onAppear {
            settings = AppSettings.load()
            consumeInitialQueryIfNeeded()
        }
        .onChange(of: settings) {
            settings.save()
            if !settings.isFirstGuessEnabled {
                firstGuessText = ""
                firstGuessElapsedSeconds = nil
                isGeneratingFirstGuess = false
            }
        }
        .onChange(of: initialQuery) {
            consumeInitialQueryIfNeeded()
        }
        #if canImport(UIKit)
        .overlay {
            KeyboardDismissTapOverlay(onTapOutsideTextInput: {
                dismissKeyboard()
            })
        }
        #endif
    }

    // MARK: - Header View
    private var headerView: some View {
        HStack {
            Button(action: { goHome() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.circlepath")
                    Text(settings.language == .french ? "Nettoyer" : "Start Over")
                        .fontWeight(.medium)
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(controlBackgroundColor)
    }

    // MARK: - Search Bar View
    private var searchBarView: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField(settings.language == .french ? "Rechercher le web..." : "Search the web...", text: $searchQuery,  axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isSearchFieldFocused)
                    .submitLabel(.search)
                    #if canImport(UIKit)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    #endif
                    .onSubmit {
                        performSearch()
                    }

                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(controlBackgroundColor)
            .cornerRadius(8)

            if let errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button(action: {
                    let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedQuery.isEmpty else { return }
                    onOfflineQuery?(trimmedQuery)
                }) {
                    Label(
                        "Chat",
                        // chat bubbles
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchService.isSearching)

                Button(action: { performSearch(generationProfile: .fast) }) {
                    Text(settings.language == .french ? "Go" : "Search")
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(searchQuery.isEmpty || searchService.isSearching)

                Button(action: { performSearch(maxResults: 10, maxScrapingChars: 7000, generationProfile: .deep) }) {
                    Label(
                        settings.language == .french ? "Deep" : "Deep",
                        systemImage: "sparkle.magnifyingglass"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(searchQuery.isEmpty || searchService.isSearching)
            }
        }
        .padding()
        .background(textBackgroundColor)
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.vertical, 8)
        
    }

    // MARK: - Results View
    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !isNoAIMode {
                    // AI Summary
                    if showingSummary {
                        summaryCard
                    }

                    // Toggle summary button
                    Button(action: { toggleSummary() }) {
                        HStack {
                            Image(systemName: showingSummary ? "eye.slash" : "sparkles")
                            if settings.language == .french {
                                Text(showingSummary ? "Masquer le résumé" : "Afficher le résumé IA")
                            } else {
                                Text(showingSummary ? "Hide Summary" : "Show AI Summary")
                            }
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                    }
                    .buttonStyle(.bordered)

                    Divider()
                }

                // Search results
                ForEach(searchResults) { result in
                    SearchResultCard(result: result)
                }
            }
            .padding()
        }
        .textSelection(.enabled)
    }

    // MARK: - Summary Card
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                Text(settings.language == .french ? "Résumé IA" : "AI Summary")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    let textToCopy = aiService.summary.isEmpty ? firstGuessText : aiService.summary
                    guard !textToCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    copyPlainTextToClipboard(textToCopy)
                    didCopySummary = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        didCopySummary = false
                    }
                } label: {
                    Image(systemName: didCopySummary ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundColor(didCopySummary ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(settings.language == .french ? "Copier" : "Copy")
                .disabled(aiService.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && firstGuessText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if aiService.isSummarizing || (settings.isFirstGuessEnabled && isGeneratingFirstGuess) {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if settings.isFirstGuessEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("First guess")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    if isGeneratingFirstGuess && firstGuessText.isEmpty {
                        Text(settings.language == .french ? "Intuition rapide en cours..." : "Generating quick intuition...")
                            .foregroundColor(.secondary)
                            .italic()
                    } else if !firstGuessText.isEmpty {
                        progressiveLaTeXText(firstGuessText, isStreaming: isGeneratingFirstGuess)
                    } else {
                        Text(settings.language == .french ? "Une intuition rapide sera affichée ici." : "A quick intuition will appear here.")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }

                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Web context answer")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                if aiService.isSummarizing {
                    Text(settings.language == .french ? "Analyse des pages web complètes..." : "Analyzing full web pages...")
                        .foregroundColor(.secondary)
                        .italic()
                }

                if !aiService.summary.isEmpty {
                    progressiveLaTeXText(aiService.summary, isStreaming: aiService.isSummarizing)

                    if !aiService.citations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()
                        Text("Top sources")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                         if let attributedCitations = try? AttributedString(
                            markdown: aiService.citations,
                            options: AttributedString.MarkdownParsingOptions(
                                interpretedSyntax: .inlineOnlyPreservingWhitespace
                            )
                        ) {
                            #if canImport(UIKit)
                            citationLinksView(from: aiService.citations)
                            #else
                            Text(attributedCitations)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .tint(.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            #endif
                        } else {
                            Text(aiService.citations)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else if !aiService.isSummarizing {
                    Text(settings.language == .french ? "Réponse avec contexte web en attente..." : "Waiting for web-context answer...")
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            // Generation time shown at the bottom-right once complete
            if !aiService.isSummarizing && !aiService.summary.isEmpty {
                HStack {
                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        if settings.isFirstGuessEnabled, let elapsed = firstGuessElapsedSeconds {
                            let label = settings.language == .french
                                ? String(format: "Première réponse en: %.1f s", elapsed)
                                : String(format: "Time to first answer: %.1f s", elapsed)
                            Text(label)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let elapsed = summaryElapsedSeconds {
                            let label = settings.language == .french
                                ? String(format: "Généré en %.1f s", elapsed)
                                : String(format: "Generated in %.1f s", elapsed)
                            Text(label)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                    }
                }
            }
        }
        .padding()
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Loading View
    private var loadingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text(settings.language == .french ? "Recherche web (DuckDuckGo + Wikipedia)..." : "Searching the web (DuckDuckGo + Wikipedia)...")
                    .foregroundColor(.secondary)

                if settings.isFirstGuessEnabled && !isNoAIMode && (isGeneratingFirstGuess || !firstGuessText.isEmpty) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("First guess")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        if isGeneratingFirstGuess && firstGuessText.isEmpty {
                            Text(settings.language == .french ? "Intuition rapide en cours..." : "Generating quick intuition...")
                                .foregroundColor(.secondary)
                                .italic()
                        } else if !firstGuessText.isEmpty {
                            progressiveLaTeXText(firstGuessText, isStreaming: isGeneratingFirstGuess)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Welcome View
    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)

                VStack(spacing: 8) {
                    Text(settings.language == .french ? "Recherchez le Web efficacement" : "Search the Web Efficiently")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(settings.language == .french ? "Obtenez des résumés concis alimentés par l'IA des résultats de recherche\nsans épuiser la batterie" : "Get concise AI-powered summaries of web results\nwithout draining your battery")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                .padding(.top)

            }
            .padding()
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Settings Panel
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(settings.language == .french ? "Paramétrages" : "Settings")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
            }

            Divider()

            // Max Search Results
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Nombre maximal de résultats" : "Max Search Results")
                        .font(.subheadline)
                    Spacer()
                    Text("\(settings.maxSearchResults)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(settings.maxSearchResults) },
                    set: { settings.maxSearchResults = Int($0) }
                ), in: Double(AppSettings.maxSearchResultsRange.lowerBound)...Double(AppSettings.maxSearchResultsRange.upperBound), step: 1)
            }

            // Temperature
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

            // First Guess Toggle
            Toggle(isOn: $settings.isFirstGuessEnabled) {
                Text(settings.language == .french ? "Activer la première réponse" : "Enable First Guess")
                    .font(.subheadline)
            }

            // Max Response Tokens
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
                    ? "Sortie max estimée : \(estimatedMaxOutputCharacters) caractères (\(estimatedMaxOutputSentences) phrases)"
                    : "Estimated max output: \(estimatedMaxOutputCharacters) characters (\(estimatedMaxOutputSentences) sentences)"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // Max Context Tokens
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

            // Model Language
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Langue du modèle" : "Model Language")
                        .font(.subheadline)
                    Spacer()
                    Text(settings.language.rawValue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(ModelLanguage.allCases, id: \.self) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding()
        .background(controlBackgroundColor)
        .cornerRadius(12)
    }

    #if canImport(UIKit)
    private func dismissKeyboard() {
        isSearchFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func openURLInSafari(_ url: URL) {
        DispatchQueue.main.async {
            let safariViewController = SFSafariViewController(url: url)
            safariViewController.modalPresentationStyle = .fullScreen
            
            if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(safariViewController, animated: true, completion: nil)
            } else {
                // Fallback to UIApplication.open if SFSafariViewController presentation fails
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        }
    }
    #endif

    private func copyPlainTextToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
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
                .frame(maxWidth: .infinity, alignment: .leading)
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

        // First pass: prefer markdown links generated by citation formatter.
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

        // Fallback: detect plain URLs when markdown parsing does not yield links.
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

        // Keep first occurrence only to avoid duplicates when sources repeat.
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

    private struct CitationLink: Identifiable {
        let id = UUID()
        let url: URL
    }
    #endif

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[SearchView] \(message)")
        #endif
    }

    @ViewBuilder
    private func progressiveLaTeXText(_ text: String, isStreaming: Bool) -> some View {
        if isStreaming {
            Text(text)
                .font(.body)
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LaTeX(ModelOutputLaTeXSanitizer.finalizeSanitizedText(text))
                .font(.body)
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if DEBUG
                .errorMode(.error)
                #endif
        }
    }
    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(settings.language == .french ? "Aucun résultat trouvé" : "No results found")
                .font(.headline)
            Text(settings.language == .french ? "Essayez une requête de recherche différente" : "Try a different search query")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions
    /// Executes a web search then optionally triggers summary generation.
    private func performSearch(maxResults: Int? = nil, maxScrapingChars: Int? = nil, noAIOnly: Bool = false, generationProfile: AIService.GenerationProfile = .fast) {
        #if canImport(UIKit)
        dismissKeyboard()
        #endif

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        searchQuery = trimmedQuery

        let requestID = UUID()
        activeSearchRequestID = requestID

        let resultsCount = maxResults ?? settings.maxSearchResults
        let scrapingChars = maxScrapingChars ?? defaultScrapingCharactersFromContextTokens

        // Clear previous results and state before starting new search
        searchResults = []
        errorMessage = nil
        aiService.summary = ""
        aiService.citations = ""
        firstGuessText = ""
        firstGuessElapsedSeconds = nil
        isGeneratingFirstGuess = false
        showingSummary = !noAIOnly
        isNoAIMode = noAIOnly
        activeGenerationProfile = generationProfile
        summaryStartTime = nil
        summaryElapsedSeconds = nil
        #if DEBUG
        aiService.debugTimings = []
        aiService.debugNotes = []
        #endif

        if !noAIOnly && settings.isFirstGuessEnabled {
            isGeneratingFirstGuess = true
            Task {
                let firstGuessStart = Date()
                let firstGuess = await aiService.generateFirstGuess(
                    query: trimmedQuery,
                    language: settings.language,
                    maxTokens: min(settings.maxResponseTokens, Self.firstGuessTokenCap),
                    onPartialUpdate: { partial in
                        guard activeSearchRequestID == requestID else { return }
                        firstGuessText = partial
                    }
                )
                guard activeSearchRequestID == requestID else { return }
                guard settings.isFirstGuessEnabled else {
                    firstGuessText = ""
                    firstGuessElapsedSeconds = nil
                    isGeneratingFirstGuess = false
                    return
                }
                firstGuessText = firstGuess
                #if DEBUG
                debugLog(firstGuessText)
                #endif
                firstGuessElapsedSeconds = Date().timeIntervalSince(firstGuessStart)
                isGeneratingFirstGuess = false
            }
        }
        
        Task {
            do {
                let searchLimit = noAIOnly
                    ? resultsCount
                    : resultsCount + Self.aiSummaryOverfetchResults
                let fetchedResults: [SearchResult]

                if generationProfile == .deep && !noAIOnly {
                    let derivedQueries = await aiService.expandSearchQueries(
                        query: trimmedQuery,
                        language: settings.language,
                        maxDerivedQueries: Self.deepSearchDerivedQueryCount
                    )

                    #if DEBUG
                    debugLog(
                        "deep query expansion count: expectedDerived=\(Self.deepSearchDerivedQueryCount), obtainedDerived=\(derivedQueries.count), inputTotal=\(1 + derivedQueries.count)"
                    )
                    let allQueries = [trimmedQuery] + derivedQueries
                    debugLog("deep query expansion: \(allQueries.joined(separator: " | "))")
                    #endif

                    fetchedResults = try await searchService.search(
                        queries: [trimmedQuery] + derivedQueries,
                        maxResultsPerQuery: searchLimit,
                        mergedLimit: searchLimit * Self.deepSearchDerivedQueryCount,
                        language: settings.language
                    )
                } else {
                    fetchedResults = try await searchService.search(
                        query: trimmedQuery,
                        maxResults: searchLimit,
                        language: settings.language
                    )
                }

                guard activeSearchRequestID == requestID else { return }
                searchResults = Array(fetchedResults.prefix(resultsCount))
                errorMessage = nil

                // Auto-generate summary only when AI mode is enabled
                if !noAIOnly && !searchResults.isEmpty {
                    showingSummary = true
                    await generateSummary(
                        maxScrapingResults: resultsCount,
                        maxScrapingChars: scrapingChars,
                        summaryResults: fetchedResults,
                        generationProfile: generationProfile
                    )
                }
            } catch {
                guard activeSearchRequestID == requestID else { return }
                errorMessage = error.localizedDescription
                searchResults = []

                #if DEBUG
                debugLog("performSearch failed: \(error.localizedDescription)")
                #endif
            }

            if activeSearchRequestID == requestID {
                isGeneratingFirstGuess = false
            }
        }
    }

    /// Toggles summary visibility and lazily generates it when first opened.
    private func toggleSummary() {
        guard !isNoAIMode else { return }
        showingSummary.toggle()
        if showingSummary && aiService.summary.isEmpty {
            Task {
                await generateSummary(generationProfile: activeGenerationProfile)
            }
        }
    }

    /// Generates a synthesized answer from current search results.
    private func generateSummary(maxScrapingResults: Int? = nil, maxScrapingChars: Int? = nil, summaryResults: [SearchResult]? = nil, generationProfile: AIService.GenerationProfile? = nil) async {
        summaryStartTime = Date()
        summaryElapsedSeconds = nil
        _ = await aiService.summarize(
            query: searchQuery,
            results: summaryResults ?? searchResults,
            maxScrapingResults: maxScrapingResults ?? settings.maxSearchResults,
            maxScrapingChars: maxScrapingChars ?? defaultScrapingCharactersFromContextTokens,
            temperature: settings.temperature,
            maxTokens: settings.maxResponseTokens,
            language: settings.language,
            profile: generationProfile ?? activeGenerationProfile
        )

        #if DEBUG
        if !aiService.summary.isEmpty {
            debugLog("Generated summary: \(aiService.summary)")
        }
        for metric in aiService.debugTimings {
            debugLog("\(metric.name): \(String(format: "%.3f s", metric.seconds))")
        }
        for note in aiService.debugNotes {
            debugLog(note)
        }
        #endif

        if let start = summaryStartTime {
            summaryElapsedSeconds = Date().timeIntervalSince(start)
        }
    }

    /// Resets all search and summary state to the initial home screen.
    private func goHome() {
        activeSearchRequestID = UUID()
        searchQuery = ""
        searchResults = []
        showingSummary = false
        isNoAIMode = false
        firstGuessText = ""
        firstGuessElapsedSeconds = nil
        isGeneratingFirstGuess = false
        aiService.summary = ""
        aiService.citations = ""
        errorMessage = nil
        summaryStartTime = nil
        summaryElapsedSeconds = nil
        #if DEBUG
        aiService.debugTimings = []
        aiService.debugNotes = []
        #endif
    }

    private func consumeInitialQueryIfNeeded() {
        guard let initialQuery else { return }
        let trimmed = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onInitialQueryHandled?()
            return
        }
        if searchQuery == trimmed && (searchService.isSearching || !searchResults.isEmpty) {
            onInitialQueryHandled?()
            return
        }
        searchQuery = trimmed
        onInitialQueryHandled?()
        performSearch()
    }
}

// MARK: - Search Result Card
/// Displays one search result row with link, source host, and snippet preview.
struct SearchResultCard: View {
    let result: SearchResult
    #if canImport(UIKit)
    private func openURLInSafari(_ url: URL) {
        DispatchQueue.main.async {
            let safariViewController = SFSafariViewController(url: url)
            safariViewController.modalPresentationStyle = .fullScreen
            
            if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(safariViewController, animated: true, completion: nil)
            } else {
                // Fallback to UIApplication.open if SFSafariViewController presentation fails
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        }
    }
    #endif

    /// Renders one result card with title link, host, and snippet.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            #if canImport(UIKit)
            Button(action: {
                if let url = URL(string: result.url) {
                    openURLInSafari(url)
                }
            }) {
                Text(result.title)
                    .font(.headline)
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            #else
            Link(destination: URL(string: result.url)!) {
                Text(result.title)
                    .font(.headline)
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            #endif

            // URL
            Text(formatURL(result.url))
                .font(.caption)
                .foregroundColor(.secondary)

            // Snippet
            Text(result.snippet)
                .font(.body)
                .foregroundColor(.primary)
                .lineLimit(5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(platformControlBackgroundColor)
        .cornerRadius(8)
    }

    private var platformControlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }

    /// Extracts a readable host from a URL string.
    private func formatURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return urlString
        }
        return host
    }
}

// MARK: - Feature Row
/// Displays one feature line in the search welcome screen.
struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    /// Renders one welcome-screen feature row with icon and text.
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    SearchView(chatService: ChatService())
        .frame(width: 800, height: 600)
}
