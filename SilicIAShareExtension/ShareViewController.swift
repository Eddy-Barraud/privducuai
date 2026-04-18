//
//  ShareViewController.swift
//  SilicIAShareExtension
//
//  Created by Copilot on 18/04/2026.
//

import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PlatformShareViewController = NSViewController
#else
import UIKit
typealias PlatformShareViewController = UIViewController
#endif

final class ShareViewController: PlatformShareViewController {
    private static let appGroupIdentifier = "group.fr.trevalim.silicia.shared"
    private static let inboxDirectoryName = "IncomingSharedFiles"
    private var didProcessInput = false

#if os(macOS)
    override func viewDidAppear() {
        super.viewDidAppear()
        launchShareProcessingIfNeeded()
    }
#else
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        launchShareProcessingIfNeeded()
    }
#endif

    private func launchShareProcessingIfNeeded() {
        guard !didProcessInput else { return }
        didProcessInput = true

        Task {
            await processSharedItems()
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func processSharedItems() async {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem],
              !extensionItems.isEmpty else {
            return
        }

        var sharedWebURLs: [String] = []
        var sharedPDFFileNames: [String] = []

        for item in extensionItems {
            let providers = item.attachments ?? []
            for provider in providers {
                if let sharedURL = await loadSharedWebURL(from: provider) {
                    sharedWebURLs.append(sharedURL.absoluteString)
                }

                if let storedPDFName = await persistSharedPDF(from: provider) {
                    sharedPDFFileNames.append(storedPDFName)
                }
            }
        }

        let deduplicatedWebURLs = deduplicated(sharedWebURLs)
        let deduplicatedPDFNames = deduplicated(sharedPDFFileNames)
        guard !deduplicatedWebURLs.isEmpty || !deduplicatedPDFNames.isEmpty else {
            return
        }

        guard let appURL = buildAppURL(sharedWebURLs: deduplicatedWebURLs, sharedPDFFileNames: deduplicatedPDFNames) else {
            return
        }

        _ = await openContainingApp(with: appURL)
    }

    private func loadSharedWebURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let item = await loadItem(from: provider, typeIdentifier: UTType.url.identifier),
           let url = extractURL(from: item),
           !url.isFileURL,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
           let item = await loadItem(from: provider, typeIdentifier: UTType.text.identifier),
           let string = item as? String,
           let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        return nil
    }

    private func persistSharedPDF(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier),
           let tempURL = await loadFileRepresentation(from: provider, typeIdentifier: UTType.pdf.identifier) {
            return persistPDF(at: tempURL, preferredFileName: provider.suggestedName)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let item = await loadItem(from: provider, typeIdentifier: UTType.fileURL.identifier),
           let sourceURL = extractURL(from: item),
           sourceURL.pathExtension.lowercased() == "pdf" {
            return persistPDF(at: sourceURL, preferredFileName: provider.suggestedName ?? sourceURL.lastPathComponent)
        }

        return nil
    }

    private func persistPDF(at sourceURL: URL, preferredFileName: String?) -> String? {
        let fileManager = FileManager.default
        guard let inboxDirectory = sharedInboxDirectoryURL() else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
            let destinationURL = uniqueInboxDestinationURL(
                in: inboxDirectory,
                sourceURL: sourceURL,
                preferredFileName: preferredFileName
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL.lastPathComponent
        } catch {
            return nil
        }
    }

    private func sharedInboxDirectoryURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            return nil
        }

        return containerURL.appendingPathComponent(Self.inboxDirectoryName, isDirectory: true)
    }

    private func uniqueInboxDestinationURL(in directory: URL, sourceURL: URL, preferredFileName: String?) -> URL {
        let fileManager = FileManager.default
        let safeName = sanitizedPDFFileName(preferredFileName: preferredFileName, sourceURL: sourceURL)
        let baseName = (safeName as NSString).deletingPathExtension
        let ext = ((safeName as NSString).pathExtension.isEmpty ? "pdf" : (safeName as NSString).pathExtension)

        var index = 0
        while true {
            let suffix = index == 0 ? "" : " (\(index + 1))"
            let candidate = directory.appendingPathComponent("\(baseName)\(suffix).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func sanitizedPDFFileName(preferredFileName: String?, sourceURL: URL) -> String {
        let rawName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRaw = (rawName?.isEmpty == false ? rawName! : sourceURL.lastPathComponent)
        let safeRaw = normalizedRaw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = safeRaw.isEmpty ? "shared.pdf" : safeRaw
        if fallback.lowercased().hasSuffix(".pdf") {
            return fallback
        }
        return "\(fallback).pdf"
    }

    private func loadItem(from provider: NSItemProvider, typeIdentifier: String) async -> Any? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    private func loadFileRepresentation(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func extractURL(from item: Any) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let nsURL = item as? NSURL {
            return nsURL as URL
        }

        if let data = item as? Data {
            return NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
        }

        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    private func buildAppURL(sharedWebURLs: [String], sharedPDFFileNames: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = "SilicIA"
        components.host = "share"
        var queryItems: [URLQueryItem] = []

        for value in sharedWebURLs {
            queryItems.append(URLQueryItem(name: "url", value: value))
        }

        for fileName in sharedPDFFileNames {
            queryItems.append(URLQueryItem(name: "sharedPDF", value: fileName))
        }

        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private func openContainingApp(with url: URL) async -> Bool {
        let didOpenViaExtensionContext = await withCheckedContinuation { continuation in
            extensionContext?.open(url, completionHandler: { success in
                continuation.resume(returning: success)
            })
        }

        #if os(macOS)
        if !didOpenViaExtensionContext {
            return NSWorkspace.shared.open(url)
        }
        #endif

        return didOpenViaExtensionContext
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
