//
//  DroppedPDFStore.swift
//  SilicIA
//
//  Created by Copilot on 18/04/2026.
//

import Foundation

/// Stores dropped PDFs in a stable temporary folder and manages cleanup.
enum DroppedPDFStore {
    private static let folderName = "SilicIADroppedPDFs"

    static var storageDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    static func persist(_ sourceURL: URL, preferredFileName: String? = nil) -> URL? {
        let fileManager = FileManager.default

        // File-picker / drag-drop URLs are security-scoped on the sandboxed
        // macOS app: we must request access before any read or copy, otherwise
        // FileManager fails with EPERM.
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let normalizedStorageDirectory = storageDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let normalizedSourceDirectory = sourceURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
            if normalizedSourceDirectory == normalizedStorageDirectory {
                return sourceURL.standardizedFileURL
            }
            let destinationURL = uniqueDestinationURL(preferredFileName: preferredFileName, sourceURL: sourceURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            #if DEBUG
            print("[DroppedPDFStore] Failed to persist PDF from \(sourceURL.path): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    @discardableResult
    static func clearAll() -> Bool {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: storageDirectory.path) {
                try fileManager.removeItem(at: storageDirectory)
            }
            return true
        } catch {
            #if DEBUG
            print("[DroppedPDFStore] Failed to clear temporary PDFs: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    private static func uniqueDestinationURL(preferredFileName: String?, sourceURL: URL) -> URL {
        let fileManager = FileManager.default
        let rawName = normalizedRawName(preferredFileName: preferredFileName, sourceURL: sourceURL)
        let base = rawName.deletingPathExtension
        let ext = rawName.pathExtension.isEmpty ? "pdf" : rawName.pathExtension

        var index = 0
        while true {
            let suffix = index == 0 ? "" : " (\(index + 1))"
            let candidateName = "\(base)\(suffix).\(ext)"
            let candidateURL = storageDirectory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }

    private static func normalizedRawName(preferredFileName: String?, sourceURL: URL) -> String {
        let candidate = preferredFileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let sourceName = sourceURL.lastPathComponent
        let fallback = sourceName.isEmpty ? "dropped.pdf" : sourceName
        let chosen = (candidate?.isEmpty == false ? candidate! : fallback)
        if chosen.lowercased().hasSuffix(".pdf") {
            return chosen
        }
        return "\(chosen).pdf"
    }
}

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }

    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
