//
//  PDFConversation.swift
//  SilicIA
//
//  Created by Eddy Barraud on 06/04/2026.
//

import SwiftData
import Foundation

/// Represents a persistent PDF-specific conversation with associated messages and PDF metadata.
@Model
final class PDFConversation {
    /// Unique identifier for the conversation.
    var id: UUID
    /// URL to the source PDF document.
    var pdfSourceURL: URL
    /// File name of the PDF for display purposes.
    var pdfFileName: String
    /// Total pages in the PDF (for reference).
    var pdfPageCount: Int
    /// Ordered list of messages in the conversation, with cascade delete rule.
    @Relationship(deleteRule: .cascade)
    var messages: [Message]
    /// Optional auto-generated title derived from the first user message.
    var title: String?
    /// Timestamp when the conversation was created.
    var createdAt: Date
    /// Timestamp of the last message (used for sorting).
    var updatedAt: Date
    /// JSON string storing context sources used in the conversation.
    var contextSources: String

    init(
        id: UUID = UUID(),
        pdfSourceURL: URL,
        pdfFileName: String,
        pdfPageCount: Int = 0,
        messages: [Message] = [],
        title: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        contextSources: String = "{}"
    ) {
        self.id = id
        self.pdfSourceURL = pdfSourceURL
        self.pdfFileName = pdfFileName
        self.pdfPageCount = pdfPageCount
        self.messages = messages
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contextSources = contextSources
    }
}
