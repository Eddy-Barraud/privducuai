//
//  FoundationModelsAvailability.swift
//  SilicIA
//
//  Created by GitHub Copilot on 29/04/2026.
//

import Foundation
import FoundationModels

enum FoundationModelsAvailability {
    /// Performs a quick, best-effort runtime check.
    ///
    /// This does *not* guarantee quality/performance; it only checks whether an on-device
    /// Foundation Models session can produce a minimal response without throwing.
    static func isAvailable() async -> Bool {
        do {
            let session = LanguageModelSession(instructions: "Reply with a single character.")
            _ = try await session.respond(
                to: "Reply with: X",
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 1)
            )
            return true
        } catch {
            return false
        }
    }

    static func warningTitle() -> String {
        preferredLanguageCode() == "fr" ? "Apple Intelligence indisponible" : "Apple Intelligence unavailable"
    }

    static func warningMessage() -> String {
        if preferredLanguageCode() == "fr" {
            return "Les modèles Apple (Foundation Models) ne sont pas disponibles sur cet appareil (souvent par manque de matériel compatible Apple Intelligence). Les réponses seront moins performantes et certaines fonctions pourront être limitées."
        }

        return "Apple’s on-device Foundation Models are not available on this device (often due to missing compatible Apple Intelligence hardware). Responses will be slower/less capable and some features may be limited."
    }

    private static func preferredLanguageCode() -> String {
        let first = Locale.preferredLanguages.first?.lowercased() ?? ""
        if first.hasPrefix("fr") { return "fr" }
        return "en"
    }
}
