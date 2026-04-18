//
//  Conversation.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import Foundation
import SwiftData

@Model
final class Conversation {
    var id: UUID
    @Relationship(deleteRule: .cascade)
    var messages: [Message]
    var title: String?
    var createdAt: Date
    var updatedAt: Date
    var contextSources: String

    init(
        id: UUID = UUID(),
        messages: [Message] = [],
        title: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        contextSources: String = "{}"
    ) {
        self.id = id
        self.messages = messages
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contextSources = contextSources
    }
}
