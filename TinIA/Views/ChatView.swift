import SwiftUI
import LaTeXSwiftUI

struct ChatView: View {
    @StateObject private var chatService = SimpleChatService()
    @State private var settings = AppSettings.load()
    @State private var showSettings = false
    @State private var messageInput = ""
    @State private var showPromotionPopup = false
    @Environment(\.colorScheme) private var colorScheme

    private var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private var textBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .textBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    private var estimatedMaxOutputCharacters: Int {
        TokenBudgeting.estimatedOutputCharacters(forTokens: settings.maxResponseTokens)
    }

    private var estimatedMaxOutputSentences: Int {
        TokenBudgeting.estimatedOutputSentences(forTokens: settings.maxResponseTokens)
    }

    private var maxAllowedContextTokensForCurrentResponse: Int {
        AppSettings.maxAllowedContextTokens(forResponseTokens: settings.maxResponseTokens)
    }

    private var effectiveContextTokens: Int {
        min(settings.maxContextTokens, maxAllowedContextTokensForCurrentResponse)
    }

    private var estimatedMaxContextWords: Int {
        TokenBudgeting.estimatedContextWords(forTokens: effectiveContextTokens)
    }

    private func maxBubbleWidth(for containerWidth: CGFloat) -> CGFloat {
        containerWidth * 0.6
    }

    var body: some View {
        VStack(spacing: 12) {
            headerView

            if showSettings {
                settingsPanel
            }

            messagesView

            if let errorMessage = chatService.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            composerView

            Text("Download SilicIA for web search")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .onChange(of: settings) {
            settings.save()
        }
        .alert("Download SilicIA for history and more", isPresented: $showPromotionPopup) {
            Button("OK", role: .cancel) {}
        }
    }

    private var headerView: some View {
        HStack {
            Button {
                startOver()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.circlepath")
                    Text(settings.language == .french ? "Nouveau" : "Start Over")
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                showPromotionPopup = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(settings.language == .french ? "Historique" : "History")
                }
            }
            .buttonStyle(.bordered)

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.language == .french ? "Parametres de chat" : "Chat Settings")
                .font(.headline)

            Picker(settings.language == .french ? "Langue" : "Language", selection: $settings.language) {
                ForEach(ModelLanguage.allCases, id: \.self) { language in
                    Text(language.rawValue).tag(language)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Temperature" : "Temperature")
                    Spacer()
                    Text(String(format: "%.2f", settings.temperature))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.temperature, in: AppSettings.temperatureRange, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Tokens de reponse max" : "Max Response Tokens")
                    Spacer()
                    Text("\(settings.maxResponseTokens)")
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.maxResponseTokens) },
                        set: {
                            settings.maxResponseTokens = Int($0)
                            settings.maxContextTokens = min(
                                settings.maxContextTokens,
                                AppSettings.maxAllowedContextTokens(forResponseTokens: settings.maxResponseTokens)
                            )
                        }
                    ),
                    in: Double(AppSettings.maxResponseTokensRange.lowerBound)...Double(AppSettings.maxResponseTokensRange.upperBound),
                    step: 100
                )

                Text(
                    settings.language == .french
                    ? "Sortie estimee : ~\(estimatedMaxOutputCharacters) caracteres (~\(estimatedMaxOutputSentences) phrases)"
                    : "Estimated output: ~\(estimatedMaxOutputCharacters) characters (~\(estimatedMaxOutputSentences) sentences)"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.language == .french ? "Tokens de contexte max" : "Max Context Tokens")
                    Spacer()
                    Text("\(effectiveContextTokens)")
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(effectiveContextTokens) },
                        set: { settings.maxContextTokens = Int($0) }
                    ),
                    in: Double(AppSettings.maxContextTokensRange.lowerBound)...Double(maxAllowedContextTokensForCurrentResponse),
                    step: 50
                )

                Text(
                    settings.language == .french
                    ? "Contexte estime : ~\(estimatedMaxContextWords) mots"
                    : "Estimated context: ~\(estimatedMaxContextWords) words"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var messagesView: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chatService.messages.isEmpty {
                        Text(settings.language == .french ? "Discutez avec le modele foundation." : "Chat with the foundation model.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(chatService.messages) { message in
                        HStack {
                            if message.role == .assistant {
                                bubbleView(message)
                                    .frame(maxWidth: maxBubbleWidth(for: geometry.size.width), alignment: .leading)
                                Spacer(minLength: 0)
                            } else {
                                Spacer(minLength: 0)
                                bubbleView(message)
                                    .frame(maxWidth: maxBubbleWidth(for: geometry.size.width), alignment: .trailing)
                            }
                        }
                        .frame(maxWidth: .infinity)
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
                .frame(maxWidth: .infinity)
            }
            .padding(8)
            .background(textBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func bubbleView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? (settings.language == .french ? "Vous" : "You") : "Assistant")
                .font(.caption)
                .foregroundColor(.secondary)

            if message.role == .assistant {
                LaTeX(ModelOutputLaTeXSanitizer.sanitize(message.content))
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                    .textSelection(.enabled)
            } else {
                Text(message.content)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            message.role == .user
            ? Color.accentColor.opacity(0.15)
            : controlBackgroundColor
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var composerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showPromotionPopup = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .foregroundColor(.secondary)
                        Text(settings.language == .french ? "Barre URL (SilicIA)" : "URL bar (SilicIA)")
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(textBackgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    showPromotionPopup = true
                } label: {
                    Label("Web", systemImage: "globe")
                }
                .buttonStyle(.bordered)

                Button {
                    showPromotionPopup = true
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(.bordered)
            }

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
    }

    private func submitMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = trimmed
        messageInput = ""

        Task {
            await chatService.sendMessage(message, settings: settings)
        }
    }

    private func startOver() {
        messageInput = ""
        chatService.resetConversation()
    }
}

private enum ModelOutputLaTeXSanitizer {
    static func sanitize(_ input: String) -> String {
        var sanitized = input
        sanitized = replacingRegex(
            in: sanitized,
            pattern: #"(?<!\s)(\\[A-Za-z]+)"#,
            with: " $1"
        )
        sanitized = replacingRegex(
            in: sanitized,
            pattern: #"(\\[A-Za-z]+)(?=[0-9A-Za-z])"#,
            with: "$1 "
        )
        sanitized = replacingDigitPowers(in: sanitized)
        sanitized = closeUnbalancedMathDelimiters(in: sanitized)
        return sanitized
    }

    private static func replacingDigitPowers(in text: String) -> String {
        var output = text
        output = replacingDigitPowerMatches(in: output, pattern: #"(?<!\\mathrm\{)(\d+)\^\{([^{}]+)\}"#)
        output = replacingDigitPowerMatches(in: output, pattern: #"(?<!\\mathrm\{)(\d+)\^(-?\d+)"#)
        return output
    }

    private static func replacingDigitPowerMatches(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let wholeRange = Range(match.range(at: 0), in: output),
                  let baseRange = Range(match.range(at: 1), in: output),
                  let exponentRange = Range(match.range(at: 2), in: output) else {
                continue
            }

            let base = String(output[baseRange])
            let exponent = String(output[exponentRange])
            output.replaceSubrange(wholeRange, with: "\\mathrm{\(base)}^\\mathrm{\(exponent)}")
        }
        return output
    }

    private static func closeUnbalancedMathDelimiters(in text: String) -> String {
        var singleDollarCount = 0
        var doubleDollarCount = 0
        var openParenCount = 0
        var closeParenCount = 0
        var openBracketCount = 0
        var closeBracketCount = 0

        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let current = characters[index]

            if current == "\\" {
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if next == "(" {
                        openParenCount += 1
                        index += 2
                        continue
                    }
                    if next == ")" {
                        closeParenCount += 1
                        index += 2
                        continue
                    }
                    if next == "[" {
                        openBracketCount += 1
                        index += 2
                        continue
                    }
                    if next == "]" {
                        closeBracketCount += 1
                        index += 2
                        continue
                    }
                    if next == "$" {
                        index += 2
                        continue
                    }
                }
                index += 1
                continue
            }

            if current == "$" {
                if index + 1 < characters.count, characters[index + 1] == "$" {
                    doubleDollarCount += 1
                    index += 2
                } else {
                    singleDollarCount += 1
                    index += 1
                }
                continue
            }

            index += 1
        }

        var output = text
        if doubleDollarCount % 2 != 0 {
            output += "$$"
        }
        if singleDollarCount % 2 != 0 {
            output += "$"
        }
        if openParenCount > closeParenCount {
            output += String(repeating: "\\)", count: openParenCount - closeParenCount)
        }
        if openBracketCount > closeBracketCount {
            output += String(repeating: "\\]", count: openBracketCount - closeBracketCount)
        }

        return output
    }

    private static func replacingRegex(in text: String, pattern: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

#Preview {
    ChatView()
        .frame(width: 980, height: 720)
}
