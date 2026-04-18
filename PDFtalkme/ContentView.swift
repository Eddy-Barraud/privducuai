//
//  ContentView.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var chatService = PDFChatService()
    @State private var settings = AppSettings.load()
    @State private var selectedPDFURL: URL?
    @State private var selectedSelectionText = ""
    @State private var prioritizedSelectionText: String?
    @State private var showImporter = false
    @State private var composerInput = ""
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        HSplitView {
            pdfPane
                .frame(minWidth: 720, idealWidth: 940)

            chatPane
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 560)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handlePDFImport
        )
        .onChange(of: settings) {
            settings.save()
        }
    }

    private var pdfPane: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(selectedPDFURL?.lastPathComponent ?? "No PDF opened")
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        showImporter = true
                    } label: {
                        Label("Open PDF", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()

                PDFDocumentView(pdfURL: selectedPDFURL) { text in
                    selectedSelectionText = text
                }
                .overlay {
                    if selectedPDFURL == nil {
                        ContentUnavailableView(
                            "Open a PDF",
                            systemImage: "doc.richtext",
                            description: Text("Use the Open PDF button to start reading and chatting.")
                        )
                    }
                }
            }

            if shouldShowSelectionPopup {
                selectionPopup
                    .padding(.top, 18)
                    .padding(.trailing, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.18), value: shouldShowSelectionPopup)
    }

    private var chatPane: some View {
        VStack(spacing: 12) {
            chatHeader

            if let message = chatService.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            messageList

            if let prioritizedSelectionText,
               !prioritizedSelectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prioritizedBadge(text: prioritizedSelectionText)
            }

            composer
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var chatHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Text("PDFtalkme")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    chatService.reset()
                } label: {
                    Label("New Chat", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Picker("Language", selection: $settings.language) {
                    ForEach(ModelLanguage.allCases, id: \.self) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Temp \(String(format: "%.2f", settings.temperature))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: $settings.temperature, in: AppSettings.temperatureRange, step: 0.05)
                }
            }
        }
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if chatService.messages.isEmpty {
                    Text("Ask questions about your PDF on the right sidebar. Selections marked with a star are forced as rank-1 retrieval context.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(chatService.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.role == .user ? "You" : "Assistant")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(message.content)
                            .textSelection(.enabled)

                        if let citations = message.citations,
                           !citations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                            if let attributed = try? AttributedString(markdown: citations) {
                                Text(attributed)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .tint(.accentColor)
                                    .textSelection(.enabled)
                            } else {
                                Text(citations)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        message.role == .user
                        ? Color.accentColor.opacity(0.15)
                        : Color(nsColor: .textBackgroundColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if chatService.isResponding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking...")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this PDF", text: $composerInput, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($isComposerFocused)
                .onSubmit {
                    submit()
                }

            Button("Send") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                composerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                chatService.isResponding
            )
        }
    }

    private var selectionPopup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Selected passage", systemImage: "star.fill")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(selectionPreview(selectedSelectionText))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)

            Button {
                prioritizedSelectionText = selectedSelectionText
            } label: {
                Label("Ask about this selection", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 8)
    }

    private func prioritizedBadge(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "star.circle.fill")
                .foregroundColor(.yellow)

            Text("Rank-1 context from selection")
                .font(.caption)
                .fontWeight(.semibold)

            Text(selectionPreview(text))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                prioritizedSelectionText = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var shouldShowSelectionPopup: Bool {
        !selectedSelectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectionPreview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 160 {
            return compact
        }
        let end = compact.index(compact.startIndex, offsetBy: 160)
        return String(compact[..<end]) + "..."
    }

    private func submit() {
        let trimmed = composerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerInput = ""

        Task {
            await chatService.sendMessage(
                trimmed,
                pdfURL: selectedPDFURL,
                prioritizedSelectionText: prioritizedSelectionText,
                settings: settings
            )
        }
    }

    private func handlePDFImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let first = urls.first else {
            return
        }
        selectedPDFURL = first
        selectedSelectionText = ""
        prioritizedSelectionText = nil
    }
}

#Preview {
    ContentView()
        .frame(width: 1400, height: 900)
}
