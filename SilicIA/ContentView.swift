//
//  ContentView.swift
//  Privducai
//
//  Created by Eddy Barraud on 23/03/2026.
//

import SwiftUI
import SwiftData

/// Root container that switches between Search Assist and Chat experiences.
struct ContentView: View {
    /// Available tabs shown in the segmented control.
    private enum AppTab: String, CaseIterable, Identifiable {
        case searchAssist = "Search Assist"
        case chat = "Chat"

        var id: String { rawValue }
    }

    @AppStorage("contentView.selectedTab") private var selectedTabRawValue: String = AppTab.searchAssist.rawValue
    @Environment(\.modelContext) private var modelContext
    @Binding var sharedURLs: [String]
    @Binding var sharedPDFs: [URL]
    @Binding var pendingSearchQuery: String?
    @StateObject private var chatService = ChatService()
    @State private var hasCheckedFoundationModels = false
    @State private var showFoundationModelsWarning = false

    private var selectedTab: AppTab {
        get { AppTab(rawValue: selectedTabRawValue) ?? .searchAssist }
        nonmutating set { selectedTabRawValue = newValue.rawValue }
    }

    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { selectedTab = $0 }
        )
    }

    /// Renders the tab picker and currently selected application screen.
    var body: some View {
        VStack(spacing: 0) {
            Picker("Application", selection: selectedTabBinding) {
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
                    SearchView(
                        initialQuery: pendingSearchQuery,
                        onInitialQueryHandled: {
                            pendingSearchQuery = nil
                        },
                        chatService: chatService,
                        onOfflineQuery: { query in
                            selectedTab = .chat
                            chatService.modelContext = modelContext
                            Task {
                                let settings = AppSettings.load()
                                await chatService.sendMessage(
                                    query,
                                    contextInput: "",
                                    pdfURLs: [],
                                    includeWebSearch: false,
                                    maxWebResults: settings.maxSearchResults,
                                    language: settings.language,
                                    temperature: settings.temperature,
                                    maxResponseTokens: settings.maxResponseTokens,
                                    maxContextTokens: settings.maxContextTokens
                                )
                            }
                        }
                    )
                case .chat:
                    ChatView(sharedURLs: $sharedURLs, sharedPDFs: $sharedPDFs, chatService: chatService)
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
        .task {
            guard !hasCheckedFoundationModels else { return }
            hasCheckedFoundationModels = true
            let available = await FoundationModelsAvailability.isAvailable()
            if !available {
                showFoundationModelsWarning = true
            }
        }
        .alert(FoundationModelsAvailability.warningTitle(), isPresented: $showFoundationModelsWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(FoundationModelsAvailability.warningMessage())
        }
    }
}

#Preview {
    ContentView(
        sharedURLs: .constant([]),
        sharedPDFs: .constant([]),
        pendingSearchQuery: .constant(nil)
    )
        .frame(width: 900, height: 700)
}
