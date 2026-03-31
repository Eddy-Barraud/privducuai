//
//  SilicIASearchWidget.swift
//  SilicIAWidget
//
//  Created by Copilot on 31/03/2026.
//

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

struct SilicIASearchWidget: Widget {
    private let searchURL = URL(string: "SilicIA://search")!

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SilicIASearchWidget", provider: SearchWidgetProvider()) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("SilicIA Search")
                        .font(.headline)
                }

                Link(destination: searchURL) {
                    HStack {
                        Image(systemName: "text.cursor")
                        Text("Start search")
                            .font(.subheadline)
                    }
                }
            }
            .padding()
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("SilicIA Search")
        .description("Quickly launch a SilicIA search from your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
