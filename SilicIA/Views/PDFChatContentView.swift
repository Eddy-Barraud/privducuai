//
//  PDFChatContentView.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import SwiftUI
import LaTeXSwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Right panel chat interface for PDF viewer with enhanced citation support.
struct PDFChatContentView: View {
    @ObservedObject var pdfChatService: PDFChatService
    @Binding var sharedPDFs: [URL]
    let onCitationTapped: (RAGChunk) -> Void

    @State private var messageInput = ""
    @State private var settings = AppSettings.load()
    @State private var showSettings = false
    @FocusState private var inputFieldFocus: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }

    private var tertiaryBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor).opacity(0.7)
        #else
        return Color(UIColor.tertiarySystemBackground)
        #endif
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                if let pdf = pdfChatService.currentPDF {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pdf.fileName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(pdf.pageCount) pages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("PDF Chat")
                        .font(.headline)
                }

                Spacer()

                Button(action: clearPDFSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text(settings.language == .french ? "Effacer" : "Clear")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(pdfChatService.currentPDF == nil && pdfChatService.messages.isEmpty)

                if showSettings {
                    Button(action: { showSettings = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if showSettings {
                settingsPanel
            }

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(pdfChatService.messages) { message in
                            messageRow(message)
                        }
                    }
                    .padding()
                }
                .onChange(of: pdfChatService.messages.count) {
                    if let last = pdfChatService.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if pdfChatService.isResponding {
                progressView
            }

            // Error message
            if let error = pdfChatService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            // Composer
            composerView

            // Drag-drop zone for new PDF
            dropZoneView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", settings.temperature))
                        .monospacedDigit()
                        .font(.caption)
                }
                Slider(value: $settings.temperature, in: 0.3...1.0, step: 0.1)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Response Tokens")
                    Spacer()
                    Text("\(settings.maxResponseTokens)")
                        .monospacedDigit()
                        .font(.caption)
                }
                Slider(value: Binding(
                    get: { Double(settings.maxResponseTokens) },
                    set: { settings.maxResponseTokens = Int($0) }
                ), in: 500...3500, step: 100)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Context Tokens")
                    Spacer()
                    Text("\(settings.maxContextTokens)")
                        .monospacedDigit()
                        .font(.caption)
                }
                Slider(value: Binding(
                    get: { Double(settings.maxContextTokens) },
                    set: { settings.maxContextTokens = Int($0) }
                ), in: 300...3500, step: 100)
            }

            Picker("Language", selection: $settings.language) {
                Text("English").tag(ModelLanguage.english)
                Text("Français").tag(ModelLanguage.french)
            }
        }
        .padding()
        .background(controlBackgroundColor)
        .cornerRadius(8)
        .padding(.horizontal)
    }

    private var progressView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Generating response...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var composerView: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about the PDF...", text: $messageInput, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(8)
                .background(tertiaryBackgroundColor)
                .cornerRadius(6)
                .focused($inputFieldFocus)
                .lineLimit(3...5)
                .submitLabel(.send)
                .onSubmit {
                    sendMessage()
                }

            Button(action: sendMessage) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pdfChatService.isResponding)

            Button(action: { showSettings.toggle() }) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(controlBackgroundColor)
    }

    private var dropZoneView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                Text("Drag PDF here or")
                    .font(.caption)
                Button("click to browse") {
                    openFileBrowser()
                }
                .font(.caption)
                .foregroundStyle(.blue)
                .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(tertiaryBackgroundColor)
        .cornerRadius(6)
        .padding()
        .onDrop(of: [.fileURL, UTType.pdf], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Message content
            Group {
                if message.role == .user {
                    Text(message.content)
                        .foregroundStyle(.primary)
                } else {
                    LaTeX(message.content)
                        .font(.body)
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(message.role == .user ? Color.blue.opacity(0.1) : tertiaryBackgroundColor)
            .cornerRadius(6)

            // Sources
            if message.role == .assistant,
               let sourceChunks = message.sourceChunks,
               !sourceChunks.isEmpty {
                PDFCitationView(
                    citations: message.citations,
                    chunks: sourceChunks,
                    onCitationTapped: onCitationTapped,
                    language: settings.language
                )
            }
        }
        .id(message.id)
    }

    private func clearPDFSession() {
        messageInput = ""
        inputFieldFocus = false
        showSettings = false
        sharedPDFs.removeAll()
        pdfChatService.clearCurrentChat()
    }

    private func sendMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messageInput = ""
        inputFieldFocus = false

        Task {
            await pdfChatService.sendMessage(
                trimmed,
                language: settings.language,
                temperature: settings.temperature,
                maxResponseTokens: settings.maxResponseTokens,
                maxContextTokens: settings.maxContextTokens
            )
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                provider.loadObject(ofClass: URL.self) { url, error in
                    guard let url = url as? URL else { return }
                    // Check if it's actually a PDF
                    guard url.pathExtension.lowercased() == "pdf" else { return }

                    Task {
                        await pdfChatService.loadPDF(url)
                    }
                }
            } else {
                // Fallback for loadFileRepresentation
                provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                    if let url = url {
                        // Copy the temporary file to a permanent location
                        let tempURL = url
                        let fileName = url.lastPathComponent
                        let tempDir = FileManager.default.temporaryDirectory
                        let permanentURL = tempDir.appendingPathComponent(fileName)

                        do {
                            // Remove existing file if it exists
                            if FileManager.default.fileExists(atPath: permanentURL.path) {
                                try FileManager.default.removeItem(at: permanentURL)
                            }
                            try FileManager.default.copyItem(at: tempURL, to: permanentURL)
                            Task {
                                await pdfChatService.loadPDF(permanentURL)
                            }
                        } catch {
                            print("Failed to copy PDF: \(error)")
                        }
                    }
                }
            }
        }
        return true
    }

    private func openFileBrowser() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task {
                    await pdfChatService.loadPDF(url)
                }
            }
        }
        #else
        // iOS/iPadOS would use DocumentPickerViewController
        #endif
    }
}

// MARK: - Preview

#Preview {
    @State var sharedPDFs: [URL] = []
    @StateObject var pdfChatService = PDFChatService()

    return PDFChatContentView(
        pdfChatService: pdfChatService,
        sharedPDFs: $sharedPDFs,
        onCitationTapped: { _ in }
    )
}
