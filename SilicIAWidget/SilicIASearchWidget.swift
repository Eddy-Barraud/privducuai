//
//  SilicIASearchWidget.swift
//  SilicIAWidget
//
//  Created by Copilot on 31/03/2026.
//

import AppIntents
import SwiftUI
import WidgetKit

private struct SearchWidgetEntry: TimelineEntry {
    let date: Date
}

private struct SearchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SearchWidgetEntry {
        SearchWidgetEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SearchWidgetEntry) -> Void) {
        completion(SearchWidgetEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SearchWidgetEntry>) -> Void) {
        completion(Timeline(entries: [SearchWidgetEntry(date: Date())], policy: .never))
    }
}

private struct OpenSilicIAWidgetSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Search with SilicIA"
    static var description = IntentDescription("Open SilicIA and run a search query.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Start Voice Search")
    var startVoiceSearch: Bool

    init() {}

    init(query: String, startVoiceSearch: Bool = false) {
        self.query = query
        self.startVoiceSearch = startVoiceSearch
    }

    func perform() async throws -> some IntentResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents()
        components.scheme = "SilicIA"
        components.host = "search"

        if !trimmedQuery.isEmpty {
            components.queryItems = [URLQueryItem(name: "q", value: trimmedQuery)]
        } else if startVoiceSearch {
            components.queryItems = [URLQueryItem(name: "voice", value: "1")]
        }

        if !trimmedQuery.isEmpty && startVoiceSearch {
            components.queryItems = [
                URLQueryItem(name: "q", value: trimmedQuery),
                URLQueryItem(name: "voice", value: "1")
            ]
        }

        guard let destination = components.url else {
            return .result()
        }

        return .result(opensIntent: OpenURLIntent(destination))
    }
}

private struct SilicIASearchWidgetView: View {
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("SilicIA Search")
                    .font(.headline)
            }

            HStack(spacing: 8) {
                TextField("Search in SilicIA", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit {
                        submitSearchIfNeeded()
                    }

                Button(intent: OpenSilicIAWidgetSearchIntent(query: query)) {
                    Image(systemName: "arrow.forward.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(intent: OpenSilicIAWidgetSearchIntent(query: query, startVoiceSearch: true)) {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func submitSearchIfNeeded() {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        Task {
            _ = try? await OpenSilicIAWidgetSearchIntent(query: trimmedQuery).perform()
        }
    }
}

struct SilicIASearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SilicIASearchWidget", provider: SearchWidgetProvider()) { _ in
            SilicIASearchWidgetView()
        }
        .configurationDisplayName("SilicIA Search")
        .description("Type a query and press Enter to search in SilicIA.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
