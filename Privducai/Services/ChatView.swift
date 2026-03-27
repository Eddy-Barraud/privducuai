//
//  ChatView.swift
//  Privducai
//
//  Created by Eddy Barraud on 27/03/2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Chat UI that sends prompts and contextual documents to `ChatService`.
struct ChatView: View {
    @StateObject private var chatService = ChatService()

    @State private var messageInput = ""
    @State private var contextInput = ""
    @State private var selectedPDFs: [URL] = []
    @State private var isDropTargeted = false
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 12) {
            messagesView

            if let errorMessage = chatService.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            composerView

            contextBoxView

            dropAreaView
        }
        .padding()
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            selectedPDFs.append(contentsOf: urls)
            selectedPDFs = deduplicateAndSortPDFs(selectedPDFs)
        }
    }

    /// Renders message history and in-progress state.
    private var messagesView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if chatService.messages.isEmpty {
                    Text("Start a chat conversation with the foundation model.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(chatService.messages) { message in
                    HStack {
                        if message.role == .assistant { Spacer(minLength: 40) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.role == .user ? "You" : "Assistant")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(message.content)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .background(
                            message.role == .user
                            ? Color.accentColor.opacity(0.15)
                            : Color(NSColor.controlBackgroundColor)
                        )
                        .cornerRadius(10)
                        if message.role == .user { Spacer(minLength: 40) }
                    }
                }

                if chatService.isResponding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking…")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
    }

    /// Renders input area and send action.
    private var composerView: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Type a message", text: $messageInput, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitMessage()
                }

            Button("Send") {
                submitMessage()
            }
            .buttonStyle(.borderedProminent)
            .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatService.isResponding)
        }
    }

    /// Renders optional free-form context and selected PDF labels.
    private var contextBoxView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context")
                .font(.subheadline)
                .fontWeight(.semibold)

            TextEditor(text: $contextInput)
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button("Add PDF") {
                    showFileImporter = true
                }
                .buttonStyle(.bordered)

                if !selectedPDFs.isEmpty {
                    Text(selectedPDFs.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    /// Renders drag-and-drop area for PDF context files.
    private var dropAreaView: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 1.5, dash: [6])
            )
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .frame(height: 56)
            .overlay(
                Text("Drop PDF here to add context")
                    .font(.caption)
                    .foregroundColor(.secondary)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handlePDFDrop)
    }

    /// Validates and dispatches the current text input to the chat service.
    private func submitMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = trimmed
        messageInput = ""

        Task {
            await chatService.sendMessage(message, contextInput: contextInput, pdfURLs: selectedPDFs)
        }
    }

    /// Handles dropped file providers and keeps PDF URLs only.
    private func handlePDFDrop(_ providers: [NSItemProvider]) -> Bool {
        let pdfProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !pdfProviders.isEmpty else { return false }

        for provider in pdfProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let fileURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?,
                      fileURL.pathExtension.lowercased() == "pdf" else {
                    return
                }

                Task { @MainActor in
                    selectedPDFs.append(fileURL)
                    selectedPDFs = deduplicateAndSortPDFs(selectedPDFs)
                }
            }
        }

        return true
    }

    /// Deduplicates dropped/imported PDFs and sorts them by displayed filename.
    private func deduplicateAndSortPDFs(_ urls: [URL]) -> [URL] {
        Array(Set(urls)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }
}
