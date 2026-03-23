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
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.accentColor)
            Text("Duck Assist")
                .font(.title)
                .fontWeight(.bold)
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Search Bar View
    private var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search the web...", text: $searchQuery)
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
                Text("Search")
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
                        Text(showingSummary ? "Hide Summary" : "Show AI Summary")
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
                Text("AI Summary")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()
                if aiService.isSummarizing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if aiService.isSummarizing {
                Text("Analyzing full web pages...")
                    .foregroundColor(.secondary)
                    .italic()
            } else if !aiService.summary.isEmpty {
                Text(LocalizedStringKey(aiService.summary))
                    .font(.body)
                    .foregroundColor(.primary)
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
            Text("Searching DuckDuckGo...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Welcome View
    private var welcomeView: some View {
        VStack(spacing: 24) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("Search the Web Efficiently")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Get concise AI-powered summaries of web results\nwithout draining your battery")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "bolt.fill", title: "Fast & Efficient", description: "Optimized for M3 MacBook")
                FeatureRow(icon: "lock.shield.fill", title: "Privacy-Focused", description: "Uses DuckDuckGo search")
                FeatureRow(icon: "brain.head.profile", title: "On-Device AI", description: "Apple NaturalLanguage framework")
            }
            .padding(.top)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No results found")
                .font(.headline)
            Text("Try a different search query")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions
    private func performSearch() {
        Task {
            do {
                searchResults = try await searchService.search(query: searchQuery)
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
        await aiService.summarize(query: searchQuery, results: searchResults)
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
