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
    private static let imageFileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp"
    ]
    private static let defaultImageExtension = "jpg"
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

        var sharedPDFFileNames: [String] = []
        var sharedImageFileNames: [String] = []

        for item in extensionItems {
            let providers = item.attachments ?? []
            for provider in providers {
                if let storedPDFName = await persistSharedPDF(from: provider) {
                    sharedPDFFileNames.append(storedPDFName)
                    continue
                }

                if let storedImageName = await persistSharedImage(from: provider) {
                    sharedImageFileNames.append(storedImageName)
                }
            }
        }

        let deduplicatedPDFNames = deduplicated(sharedPDFFileNames)
        let deduplicatedImageNames = deduplicated(sharedImageFileNames)

        guard !deduplicatedPDFNames.isEmpty
            || !deduplicatedImageNames.isEmpty else {
            return
        }

        guard let appURL = buildAppURL(
            sharedPDFFileNames: deduplicatedPDFNames,
            sharedImageFileNames: deduplicatedImageNames
        ) else {
            return
        }

        _ = await openContainingApp(with: appURL)
    }

    private func persistSharedPDF(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let stored = await persistFileRepresentation(
                from: provider,
                typeIdentifier: UTType.pdf.identifier,
                allowedExtensions: ["pdf"],
                defaultExtension: "pdf",
                fallbackName: "shared.pdf",
                preferredFileName: provider.suggestedName
            ) {
                return stored
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let item = await loadItem(from: provider, typeIdentifier: UTType.fileURL.identifier),
           let sourceURL = extractURL(from: item),
           sourceURL.pathExtension.lowercased() == "pdf" {
            return persistPDF(at: sourceURL, preferredFileName: provider.suggestedName ?? sourceURL.lastPathComponent)
        }

        return nil
    }

    private func persistSharedImage(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
              || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        // Walk the provider's specific registered UTIs (e.g. public.heic,
        // public.jpeg, public.png) first — these often work where the
        // generic `public.image` parent UTI returns nil, which is the
        // common case for Photos.app on iOS.
        let imageUTIs = provider.registeredTypeIdentifiers.filter { id in
            guard let utType = UTType(id) else { return false }
            return utType.conforms(to: .image)
        }
        let candidates = imageUTIs.isEmpty ? [UTType.image.identifier] : imageUTIs

        for typeID in candidates {
            // Pass 1: file representation (cheaper for large files; copy
            // happens inside the completion handler so the OS doesn't
            // delete the temp file before we read it).
            if let stored = await persistFileRepresentation(
                from: provider,
                typeIdentifier: typeID,
                allowedExtensions: Self.imageFileExtensions,
                defaultExtension: Self.fileExtension(for: typeID) ?? Self.defaultImageExtension,
                fallbackName: "shared.\(Self.defaultImageExtension)",
                preferredFileName: provider.suggestedName
            ) {
                return stored
            }

            // Pass 2: raw data fallback. Some Photos.app shares only
            // expose `loadDataRepresentation` reliably (especially HEIC
            // originals).
            if let stored = await persistDataRepresentation(
                from: provider,
                typeIdentifier: typeID,
                allowedExtensions: Self.imageFileExtensions,
                defaultExtension: Self.fileExtension(for: typeID) ?? Self.defaultImageExtension,
                fallbackName: "shared.\(Self.defaultImageExtension)",
                preferredFileName: provider.suggestedName
            ) {
                return stored
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let item = await loadItem(from: provider, typeIdentifier: UTType.fileURL.identifier),
           let sourceURL = extractURL(from: item),
           Self.imageFileExtensions.contains(sourceURL.pathExtension.lowercased()) {
            return persistImage(at: sourceURL, preferredFileName: provider.suggestedName ?? sourceURL.lastPathComponent)
        }

        return nil
    }

    /// Maps a UTType identifier (e.g. `public.heic`, `public.jpeg`) to the
    /// file extension we save it under. Falls back to nil for unknown
    /// types; caller substitutes a default.
    private static func fileExtension(for typeID: String) -> String? {
        guard let utType = UTType(typeID),
              let ext = utType.preferredFilenameExtension else {
            return nil
        }
        return imageFileExtensions.contains(ext.lowercased()) ? ext.lowercased() : nil
    }

    /// Loads a file representation from the provider AND copies it to the
    /// app-group inbox *inside the completion handler* — required because
    /// iOS deletes the temp file the moment that closure returns (most
    /// visible when sharing images from Photos.app, which fails reliably
    /// if the copy happens later). Returns the persisted file name or nil.
    private func persistFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        allowedExtensions: Set<String>,
        defaultExtension: String,
        fallbackName: String,
        preferredFileName: String?
    ) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let stored = self.persistFile(
                    at: url,
                    preferredFileName: preferredFileName ?? url.lastPathComponent,
                    allowedExtensions: allowedExtensions,
                    defaultExtension: defaultExtension,
                    fallbackName: fallbackName
                )
                continuation.resume(returning: stored)
            }
        }
    }

    /// Loads the provider's bytes for `typeIdentifier` as raw `Data` and
    /// writes them to the app-group inbox. Used as a fallback when
    /// `persistFileRepresentation` returns nil.
    private func persistDataRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        allowedExtensions: Set<String>,
        defaultExtension: String,
        fallbackName: String,
        preferredFileName: String?
    ) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data, !data.isEmpty,
                      let inbox = self.sharedInboxDirectoryURL() else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                    // Synthesise a stand-in source URL purely so
                    // `uniqueInboxDestinationURL` can derive a base name.
                    let synthSource = URL(fileURLWithPath: preferredFileName ?? fallbackName)
                    let destination = self.uniqueInboxDestinationURL(
                        in: inbox,
                        sourceURL: synthSource,
                        preferredFileName: preferredFileName,
                        allowedExtensions: allowedExtensions,
                        defaultExtension: defaultExtension,
                        fallbackName: fallbackName
                    )
                    try data.write(to: destination, options: .atomic)
                    continuation.resume(returning: destination.lastPathComponent)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func persistPDF(at sourceURL: URL, preferredFileName: String?) -> String? {
        persistFile(
            at: sourceURL,
            preferredFileName: preferredFileName,
            allowedExtensions: ["pdf"],
            defaultExtension: "pdf",
            fallbackName: "shared.pdf"
        )
    }

    private func persistImage(at sourceURL: URL, preferredFileName: String?) -> String? {
        persistFile(
            at: sourceURL,
            preferredFileName: preferredFileName,
            allowedExtensions: Self.imageFileExtensions,
            defaultExtension: Self.defaultImageExtension,
            fallbackName: "shared.\(Self.defaultImageExtension)"
        )
    }

    /// Copies a single file into the app-group inbox, generating a unique
    /// destination filename. Returns the destination's `lastPathComponent`
    /// so the host app can locate it again.
    private func persistFile(
        at sourceURL: URL,
        preferredFileName: String?,
        allowedExtensions: Set<String>,
        defaultExtension: String,
        fallbackName: String
    ) -> String? {
        let fileManager = FileManager.default
        guard let inboxDirectory = sharedInboxDirectoryURL() else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
            let destinationURL = uniqueInboxDestinationURL(
                in: inboxDirectory,
                sourceURL: sourceURL,
                preferredFileName: preferredFileName,
                allowedExtensions: allowedExtensions,
                defaultExtension: defaultExtension,
                fallbackName: fallbackName
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

    private func uniqueInboxDestinationURL(
        in directory: URL,
        sourceURL: URL,
        preferredFileName: String?,
        allowedExtensions: Set<String>,
        defaultExtension: String,
        fallbackName: String
    ) -> URL {
        let fileManager = FileManager.default
        let safeName = sanitizedFileName(
            preferredFileName: preferredFileName,
            sourceURL: sourceURL,
            allowedExtensions: allowedExtensions,
            defaultExtension: defaultExtension,
            fallbackName: fallbackName
        )
        let baseName = (safeName as NSString).deletingPathExtension
        let rawExt = (safeName as NSString).pathExtension.lowercased()
        let ext = allowedExtensions.contains(rawExt) ? rawExt : defaultExtension

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

    private func sanitizedFileName(
        preferredFileName: String?,
        sourceURL: URL,
        allowedExtensions: Set<String>,
        defaultExtension: String,
        fallbackName: String
    ) -> String {
        let rawName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRaw = (rawName?.isEmpty == false ? rawName! : sourceURL.lastPathComponent)
        let safeRaw = normalizedRaw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = safeRaw.isEmpty ? fallbackName : safeRaw
        let fallbackExt = (fallback as NSString).pathExtension.lowercased()
        if allowedExtensions.contains(fallbackExt) {
            return fallback
        }
        return "\(fallback).\(defaultExtension)"
    }

    private func loadItem(from provider: NSItemProvider, typeIdentifier: String) async -> Any? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
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

    private func buildAppURL(
        sharedPDFFileNames: [String],
        sharedImageFileNames: [String]
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "SilicIA"
        components.host = "share"
        var queryItems: [URLQueryItem] = []

        for fileName in sharedPDFFileNames {
            queryItems.append(URLQueryItem(name: "sharedPDF", value: fileName))
        }

        for fileName in sharedImageFileNames {
            queryItems.append(URLQueryItem(name: "sharedImage", value: fileName))
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
        if didOpenViaExtensionContext { return true }

        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        // iOS-specific fallback. `extensionContext.open` from a share
        // extension is documented to be flaky even when the URL scheme
        // is properly registered — observed empirically to return false
        // on otherwise-valid `silicia://share?…` URLs. Walk the responder
        // chain to find a target that responds to `openURL:` (typically
        // UIApplication a few frames up), which is a long-standing
        // share-extension workaround that still works on current iOS.
        return await MainActor.run {
            var responder: UIResponder? = self
            while let current = responder {
                if let app = current as? UIApplication {
                    app.open(url, options: [:], completionHandler: nil)
                    return true
                }
                let selector = NSSelectorFromString("openURL:")
                if current.responds(to: selector) {
                    _ = current.perform(selector, with: url)
                    return true
                }
                responder = current.next
            }
            return false
        }
        #endif
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
