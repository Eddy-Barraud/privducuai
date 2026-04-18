//
//  Message.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import Foundation
import SwiftData

@Model
final class Message {
    var id: UUID
    var role: String
    var content: String
    var citations: String?
    var timestamp: Date

    init(id: UUID = UUID(), role: String, content: String, citations: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
        self.timestamp = timestamp
    }
}
