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

private struct SilicIASearchWidgetView: View {
    var body: some View {
        ZStack {
            Color.clear
            Image(systemName: "magnifyingglass.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.accentColor)
                .padding(20)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct SilicIASearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SilicIASearchWidget", provider: SearchWidgetProvider()) { _ in
            SilicIASearchWidgetView()
        }
        .configurationDisplayName("SilicIA Search")
        .description("Quick access to SilicIA search.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
