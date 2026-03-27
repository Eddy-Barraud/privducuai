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
                    SearchView()
                case .chat:
                    ChatView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 700)
}
