//
//  SearchView.swift
//  Privducai
//
//  Created by Claude on 23/03/2026.
//

import SwiftUI

struct SearchView: View {
    @StateObject private var searchService = DuckDuckGoService()
    @StateObject private var aiService = AIService()

    @State private var searchQuery = ""
    @State private var searchResults: [SearchResult] = []
    @State private var showingSummary = false
    @State private var errorMessage: String?

    // Settings
    @State private var settings = AppSettings()
    @State private var showSettings = false

    // Generation timer
    @State private var summaryStartTime: Date? = nil
    @State private var summaryElapsedSeconds: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Search Bar
            searchBarView

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
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header View
    private var headerView: some View {
        HStack {
            Button(action: { goHome() }) {
                HStack {
                    Image(systemName: "arrow.2.circlepath")
                        .font(.system(size: 32))
                        .foregroundColor(.accentColor)
                    Text("Search Assist")
                        .font(.title)
                        .fontWeight(.bold)
                }
            }
            .buttonStyle(.plain)
            
            Spacer()

            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Search Bar View
    private var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField(settings.language == .french ? "Rechercher le web..." : "Search the web...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.body)
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

            Button(action: performSearch) {
                Text(settings.language == .french ? "Rechercher" : "Search")
                    .fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .disabled(searchQuery.isEmpty || searchService.isSearching)
        }
        .padding()
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Results View
    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 16) {
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

                // Search results
                ForEach(searchResults) { result in
                    SearchResultCard(result: result)
                }
            }
            .padding()
        }
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
                if aiService.isSummarizing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if aiService.isSummarizing {
                Text(settings.language == .french ? "Analyse des pages web complètes..." : "Analyzing full web pages...")
                    .foregroundColor(.secondary)
                    .italic()
            } else if !aiService.summary.isEmpty {
                Text(LocalizedStringKey(aiService.summary))
                    .font(.body)
                    .foregroundColor(.primary)
            }

            // Generation time shown at the bottom-right once complete
            if !aiService.isSummarizing, let elapsed = summaryElapsedSeconds {
                HStack {
                    Spacer()
                    let label = settings.language == .french
                        ? String(format: "Généré en %.1f s", elapsed)
                        : String(format: "Generated in %.1f s", elapsed)
                    Text(label)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text(settings.language == .french ? "Recherche sur DuckDuckGo..." : "Searching DuckDuckGo...")
                .foregroundColor(.secondary)
        }
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

                VStack(alignment: .leading, spacing: 12) {
                    if settings.language == .french {
                        FeatureRow(icon: "bolt.fill", title: "Rapide et efficace", description: "Optimisé pour MacBook M3")
                        FeatureRow(icon: "lock.shield.fill", title: "Axé sur la confidentialité", description: "Utilise la recherche DuckDuckGo")
                        FeatureRow(icon: "brain.head.profile", title: "IA sur l'appareil", description: "Modèles de fondation Apple")
                    } else {
                        FeatureRow(icon: "bolt.fill", title: "Fast & Efficient", description: "Optimized for M3 MacBook")
                        FeatureRow(icon: "lock.shield.fill", title: "Privacy-Focused", description: "Uses DuckDuckGo search")
                        FeatureRow(icon: "brain.head.profile", title: "On-Device AI", description: "Apple Foundation Models")
                    }
                }
                .padding(.top)

                // Settings Panel
                if showSettings {
                    settingsPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut, value: showSettings)
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
                    set: { settings.maxResponseTokens = Int($0) }
                ), in: Double(AppSettings.maxResponseTokensRange.lowerBound)...Double(AppSettings.maxResponseTokensRange.upperBound), step: 100)
            }

            // Max Scraping Characters
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Caractères de scraping max" : "Max Scraping Characters")
                        .font(.subheadline)
                    Spacer()
                    Text("\(settings.maxScrapingCharacters)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(settings.maxScrapingCharacters) },
                    set: { settings.maxScrapingCharacters = Int($0) }
                ), in: Double(AppSettings.maxScrapingCharactersRange.lowerBound)...Double(AppSettings.maxScrapingCharactersRange.upperBound), step: 500)
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
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
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
    private func performSearch() {
        // Clear previous results and state before starting new search
        searchResults = []
        aiService.summary = ""
        showingSummary = false
        
        Task {
            do {
                searchResults = try await searchService.search(query: searchQuery, maxResults: settings.maxSearchResults)
                errorMessage = nil

                // Auto-generate summary for the first search
                if !searchResults.isEmpty && !showingSummary {
                    showingSummary = true
                    await generateSummary()
                }
            } catch {
                errorMessage = error.localizedDescription
                searchResults = []
            }
        }
    }

    private func toggleSummary() {
        showingSummary.toggle()
        if showingSummary && aiService.summary.isEmpty {
            Task {
                await generateSummary()
            }
        }
    }

    private func generateSummary() async {
        summaryStartTime = Date()
        summaryElapsedSeconds = nil
        _ = await aiService.summarize(
            query: searchQuery,
            results: searchResults,
            maxScrapingResults: settings.maxSearchResults,
            maxScrapingChars: settings.maxScrapingCharacters,
            temperature: settings.temperature,
            maxTokens: settings.maxResponseTokens,
            language: settings.language
        )
        if let start = summaryStartTime {
            summaryElapsedSeconds = Date().timeIntervalSince(start)
        }
    }

    private func goHome() {
        searchQuery = ""
        searchResults = []
        showingSummary = false
        aiService.summary = ""
        errorMessage = nil
        summaryStartTime = nil
        summaryElapsedSeconds = nil
    }
}

// MARK: - Search Result Card
struct SearchResultCard: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Link(destination: URL(string: result.url)!) {
                Text(result.title)
                    .font(.headline)
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)

            // URL
            Text(formatURL(result.url))
                .font(.caption)
                .foregroundColor(.secondary)

            // Snippet
            Text(result.snippet)
                .font(.body)
                .foregroundColor(.primary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func formatURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return urlString
        }
        return host
    }
}

// MARK: - Feature Row
struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

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
    SearchView()
        .frame(width: 800, height: 600)
}
