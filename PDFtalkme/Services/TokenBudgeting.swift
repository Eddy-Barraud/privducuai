//
//  TokenBudgeting.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import Foundation

enum TokenBudgeting {
    static let contextWindowLimit = 4096
    static let avgCharsPerToken = 3
    static let avgCharsPerSentence = 140
    static let avgCharsPerWord = 5

    static let instructionTokens = 100
    static let promptOverheadTokens = 80
    static let minContextTokens = 300

    static func clampedOutputTokens(
        requestedMaxTokens: Int,
        instructionTokens: Int = instructionTokens,
        promptOverheadTokens: Int = promptOverheadTokens,
        minContextTokens: Int = minContextTokens
    ) -> Int {
        let maxOutputTokens = max(
            contextWindowLimit - instructionTokens - promptOverheadTokens - minContextTokens,
            1
        )
        return min(max(requestedMaxTokens, 1), maxOutputTokens)
    }

    static func maxAvailableContextTokens(
        maxOutputTokens: Int,
        instructionTokens: Int = instructionTokens,
        promptOverheadTokens: Int = promptOverheadTokens,
        minContextTokens: Int = minContextTokens
    ) -> Int {
        let effectiveOutputTokens = clampedOutputTokens(
            requestedMaxTokens: maxOutputTokens,
            instructionTokens: instructionTokens,
            promptOverheadTokens: promptOverheadTokens,
            minContextTokens: minContextTokens
        )
        return max(contextWindowLimit - instructionTokens - promptOverheadTokens - effectiveOutputTokens, minContextTokens)
    }

    static func clampedContextTokens(
        requestedContextTokens: Int,
        maxOutputTokens: Int,
        settingsRange: ClosedRange<Int>,
        instructionTokens: Int = instructionTokens,
        promptOverheadTokens: Int = promptOverheadTokens,
        minContextTokens: Int = minContextTokens
    ) -> Int {
        let contextBudgetCap = maxAvailableContextTokens(
            maxOutputTokens: maxOutputTokens,
            instructionTokens: instructionTokens,
            promptOverheadTokens: promptOverheadTokens,
            minContextTokens: minContextTokens
        )
        let boundedUpper = min(settingsRange.upperBound, contextBudgetCap)
        let boundedLower = min(settingsRange.lowerBound, boundedUpper)
        return min(max(requestedContextTokens, boundedLower), boundedUpper)
    }

    static func estimatedTokens(forApproxWords words: Int) -> Int {
        max(1, Int((Double(max(words, 0)) * Double(avgCharsPerWord)) / Double(avgCharsPerToken)))
    }

    static func estimatedTokens(forApproxCharacters characters: Int) -> Int {
        max(0, Int(ceil(Double(max(characters, 0)) / Double(avgCharsPerToken))))
    }

    static func estimatedContextCharacters(forTokens tokens: Int) -> Int {
        max(tokens, 0) * avgCharsPerToken
    }

    static func estimatedContextWords(forTokens tokens: Int) -> Int {
        max(1, estimatedContextCharacters(forTokens: tokens) / avgCharsPerWord)
    }

    static func estimatedOutputCharacters(forTokens tokens: Int) -> Int {
        max(tokens, 0) * avgCharsPerToken
    }

    static func truncateToApproxWordCount(_ text: String, maxWords: Int) -> String {
        guard maxWords > 0 else { return "" }
        var wordsSeen = 0
        var inWord = false
        var cutIndex: String.Index?

        for index in text.indices {
            let character = text[index]
            let isWordCharacter = character.isLetter || character.isNumber
            if isWordCharacter {
                if !inWord {
                    wordsSeen += 1
                    if wordsSeen > maxWords {
                        cutIndex = index
                        break
                    }
                }
                inWord = true
            } else {
                inWord = false
            }
        }

        guard let cutIndex else {
            return text
        }

        return String(text[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func maxContextCharacters(
        maxOutputTokens: Int,
        contextUtilizationFactor: Double,
        instructionTokens: Int = instructionTokens,
        promptOverheadTokens: Int = promptOverheadTokens,
        minContextTokens: Int = minContextTokens,
        avgCharsPerToken: Int = avgCharsPerToken
    ) -> Int {
        let effectiveOutputTokens = clampedOutputTokens(
            requestedMaxTokens: maxOutputTokens,
            instructionTokens: instructionTokens,
            promptOverheadTokens: promptOverheadTokens,
            minContextTokens: minContextTokens
        )
        let reservedTokens = instructionTokens + promptOverheadTokens + effectiveOutputTokens
        let availableTokens = max(contextWindowLimit - reservedTokens, 0)
        return Int(Double(availableTokens * avgCharsPerToken) * contextUtilizationFactor)
    }
}
