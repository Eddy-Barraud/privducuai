//
//  ContentView.swift
//  Privducai
//
//  Created by Eddy Barraud on 23/03/2026.
//

import SwiftUI

/// Root container that switches between Search Assist and Chat experiences.
struct ContentView: View {
    /// Available tabs shown in the segmented control.
    private enum AppTab: String, CaseIterable, Identifiable {
        case searchAssist = "Search Assist"
        case chat = "Chat"

        var id: String { rawValue }
    }

    @State private var selectedTab: AppTab = .searchAssist
    @Binding var sharedURLs: [String]
    @Binding var sharedPDFs: [URL]
    @Binding var pendingSearchQuery: String?

    /// Renders the tab picker and currently selected application screen.
    var body: some View {
        VStack(spacing: 0) {
            Picker("Application", selection: $selectedTab) {
                Text(AppTab.searchAssist.rawValue).tag(AppTab.searchAssist)
                Text(AppTab.chat.rawValue).tag(AppTab.chat)
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider()

            Group {
                switch selectedTab {
                case .searchAssist:
                    SearchView(initialQuery: pendingSearchQuery, onInitialQueryHandled: {
                        pendingSearchQuery = nil
                    })
                case .chat:
                    ChatView(sharedURLs: $sharedURLs, sharedPDFs: $sharedPDFs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: sharedURLs) {
            if !sharedURLs.isEmpty {
                selectedTab = .chat
            }
        }
        .onChange(of: sharedPDFs) {
            if !sharedPDFs.isEmpty {
                selectedTab = .chat
            }
        }
        .onChange(of: pendingSearchQuery) {
            if pendingSearchQuery != nil {
                selectedTab = .searchAssist
            }
        }
    }
}

#Preview {
    ContentView(sharedURLs: .constant([]), sharedPDFs: .constant([]), pendingSearchQuery: .constant(nil))
        .frame(width: 900, height: 700)
}
