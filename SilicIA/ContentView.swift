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
    @State private var chatResetID = UUID()
    @State private var searchResetID = UUID()
    @Binding var sharedURLs: [String]
    @Binding var sharedPDFs: [URL]

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
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button(action: {
                                // Recreate SearchView to reset its state
                                searchResetID = UUID()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.2.circlepath")
                                    Text("Start Over")
                                        .fontWeight(.medium)
                                }
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))

                        Divider()

                        SearchView()
                            .id(searchResetID)
                    }
                case .chat:
                    VStack(spacing: 0) {
                        // Chat header with Start Over button
                        HStack {
                            Spacer()
                            Button(action: {
                                // Clear any shared context and recreate ChatView to reset conversation
                                sharedURLs.removeAll()
                                sharedPDFs.removeAll()
                                chatResetID = UUID()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.2.circlepath")
                                    Text("Start Over")
                                        .fontWeight(.medium)
                                }
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))

                        Divider()

                        ChatView(sharedURLs: $sharedURLs, sharedPDFs: $sharedPDFs)
                            .id(chatResetID)
                    }
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
    }
}

#Preview {
    ContentView(sharedURLs: .constant([]), sharedPDFs: .constant([]))
        .frame(width: 900, height: 700)
}
