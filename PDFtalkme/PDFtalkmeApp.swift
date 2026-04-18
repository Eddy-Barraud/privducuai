//
//  PDFtalkmeApp.swift
//  PDFtalkme
//
//  Created by OpenCode on 18/04/2026.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PDFtalkmeApp: App {
    @StateObject private var openRouter = PDFOpenRouter.shared
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL(perform: handleIncomingURL)
#if os(macOS)
                .onAppear {
                    appDelegate.onOpenURLs = { urls in
                        openRouter.enqueue(urls)
                    }

                    let pending = appDelegate.drainPendingURLs()
                    if !pending.isEmpty {
                        openRouter.enqueue(pending)
                    }
                }
#endif
        }
        .defaultSize(width: 1460, height: 940)
    }

    private func handleIncomingURL(_ url: URL) {
        openRouter.enqueue([url])
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpenURLs {
            onOpenURLs(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func drainPendingURLs() -> [URL] {
        defer { pendingURLs.removeAll() }
        return pendingURLs
    }
}
#endif
