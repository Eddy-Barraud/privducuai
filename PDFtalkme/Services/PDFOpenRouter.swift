//
//  PDFOpenRouter.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import Foundation
import Combine

@MainActor
final class PDFOpenRouter: ObservableObject {
    static let shared = PDFOpenRouter()

    @Published var signal = UUID()

    private var pendingURLs: [URL] = []

    private init() {}

    func enqueue(_ urls: [URL]) {
        let filtered = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !filtered.isEmpty else { return }
        pendingURLs.append(contentsOf: filtered)
        signal = UUID()
    }

    func drain() -> [URL] {
        defer { pendingURLs.removeAll() }
        return pendingURLs
    }
}
