//
//  PrivducaiApp.swift
//  Privducai
//
//  Created by Eddy Barraud on 23/03/2026.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
/// Application entry point that launches the main content window.
struct PrivducaiApp: App {
    @State private var sharedURLs: [String] = []
    @State private var sharedPDFs: [URL] = []
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif

    /// Declares the app's primary window scene.
    var body: some Scene {
        WindowGroup {
            ContentView(sharedURLs: $sharedURLs, sharedPDFs: $sharedPDFs)
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
                }
#endif
        }
    }

    /// Routes incoming shared URLs and files to chat context.
    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL, url.pathExtension.lowercased() == "pdf" {
            sharedPDFs.append(url)
            sharedPDFs = Array(Set(sharedPDFs))
            return
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           url.scheme?.lowercased() == "privducai",
           let sharedURL = components.queryItems?.first(where: { $0.name == "url" })?.value {
            sharedURLs.append(sharedURL)
            return
        }

        let absolute = url.absoluteString
        if absolute.hasPrefix("http://") || absolute.hasPrefix("https://") {
            sharedURLs.append(absolute)
        }
    }
}

#if os(macOS)
/// Receives URLs and files opened by macOS (Finder/Preview/Safari share flows).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenURLs?(urls)
    }
}
#endif
