//
//  SilicIAApp.swift
//  SilicIA
//
//  Created by Eddy Barraud on 23/03/2026.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
/// Application entry point that launches the main content window.
struct SilicIAApp: App {
    @State private var sharedURLs: [String] = []
    @State private var sharedPDFs: [URL] = []
    @State private var pendingSearchQuery: String?
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    /// Declares the app's primary window scene.
    var body: some Scene {
        WindowGroup {
            ContentView(
                sharedURLs: $sharedURLs,
                sharedPDFs: $sharedPDFs,
                pendingSearchQuery: $pendingSearchQuery
            )
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
#if os(macOS)
                .onAppear {
                    appDelegate.onOpenURLs = { urls in
                        for url in urls {
                            handleIncomingURL(url)
                        }
                    }
                    let pending = appDelegate.drainPendingURLs()
                    if !pending.isEmpty {
                        for url in pending {
                            handleIncomingURL(url)
                        }
                    }
                }
#endif
        }
        #if os(macOS)
            .defaultSize(width: 1284, height: 1662)
        #endif
    }

    /// Routes incoming shared URLs and files to chat context.
    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL, url.pathExtension.lowercased() == "pdf" {
            sharedPDFs = [url]
            return
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           url.scheme?.lowercased() == "silicia",
           let queryItems = components.queryItems {
            if (components.host?.lowercased() == "search" || components.path.lowercased().contains("search")),
               queryItems.first(where: { $0.name == "q" || $0.name == "query" })?.value == nil {
                pendingSearchQuery = ""
                return
            }
            if let searchQuery = queryItems.first(where: { $0.name == "q" || $0.name == "query" })?.value,
               !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingSearchQuery = searchQuery
                return
            }
            if let sharedURL = queryItems.first(where: { $0.name == "url" })?.value,
               !sharedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sharedURLs = [sharedURL]
                return
            }
        }

        let absolute = url.absoluteString
        if absolute.hasPrefix("http://") || absolute.hasPrefix("https://") {
            sharedURLs = [absolute]
        }
    }
}

#if os(macOS)
/// Receives URLs and files opened by macOS (Finder/Preview/Safari share flows).
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            return true
    }
}
#endif
