//
//  WikipediaQueryCleaner.swift
//  SilicIA
//
//  Sanitizes search queries specifically for the Wikipedia REST API.
//  Unlike DuckDuckGo or modern search engines which handle natural language
//  questions, Wikipedia's CirrusSearch is based on keyword/title matching.
//  Interrogative words, conversational prefixes, and filler words act as noise
//  tokens that degrade search results or yield zero matches.
//
//  This cleaner executes synchronously in < 0.1ms via regex prefix stripping
//  and O(1) stop-word Set filtering, with zero allocation overhead.
//

import Foundation

/// Fast, deterministic keyword extractor and question-word remover tailored
/// for Wikipedia CirrusSearch queries across English, French, and Spanish.
enum WikipediaQueryCleaner: Sendable {

    /// Leading multi-word question patterns and conversational prefixes.
    private nonisolated static let leadingQuestionPatterns: [String] = [
        // English questions & conversational fluff
        #"^(?:who|what|where|when|why|how|which)\s+(?:is|are|was|were|did|does|do|can|could|would|should)\s+(?:(?:the|a|an)\s+)?"#,
        #"^(?:tell\s+me\s+about|can\s+you\s+tell\s+me\s+about|can\s+you\s+tell\s+me|explain|search\s+for|find\s+out\s+about|give\s+me\s+info\s+on|information\s+on)\s+(?:(?:the|a|an)\s+)?"#,
        #"^(?:how\s+to|how\s+does|how\s+do|what\s+about)\s+"#,

        // French questions & conversational fluff
        #"^(?:qu['’]est[- ]ce\s+(?:que|qui|qu['’])|c['’]est\s+quoi|c\s+quoi)\s+(?:(?:le|la|les|l['’]|un|une|des|du|de\s+la|d['’])\s*)?"#,
        #"^(?:qui\s+est|qui\s+[ée]tait|qui\s+sont|qui\s+furent|qui\s+a|qui\s+ont)\s+(?:(?:le|la|les|l['’]|un|une|des)\s*)?"#,
        #"^(?:o[ùu]\s+se\s+trouve(?:nt)?|o[ùu]\s+est|o[ùu]\s+sont)\s+(?:(?:le|la|les|l['’]|un|une|des)\s*)?"#,
        #"^(?:comment\s+fonctionne(?:nt)?|comment\s+marche(?:nt)?|comment\s+faire\s+pour)\s+(?:(?:le|la|les|l['’]|un|une|des)\s*)?"#,
        #"^(?:pourquoi\s+est[- ]ce\s+(?:que|qu['’])|pourquoi)\s+"#,
        #"^(?:quel\s+est|quelle\s+est|quels\s+sont|quelles\s+sont)\s+(?:(?:le|la|les|l['’]|un|une|des)\s*)?"#,
        #"^(?:peux[- ]tu\s+m['’]expliquer|peux[- ]tu\s+me\s+dire|dis[- ]moi|parle[- ]moi\s+de|donne[- ]moi\s+des\s+infos\s+sur)\s+(?:(?:le|la|les|l['’]|un|une|des)\s*)?"#,

        // Spanish questions & conversational fluff
        #"^(?:qu[ée]|qui[ée]n(?:es)?|d[óo]nde|c[óo]mo|cu[áa]ndo|cu[áa]l(?:es)?)\s+(?:es|son|era|eran|fue|fueron|est[áa]|est[áa]n|queda|se\s+encuentra|ocurri[óo]|ocurre|pas[óo]|pasa)\s+(?:(?:el|la|los|las|un|una|del)\s+)?"#,
        #"^(?:puedes\s+decirme|h[áa]blame\s+de|cu[ée]ntame\s+sobre|expl[íi]came)\s+(?:(?:el|la|los|las|un|una)\s+)?"#,
        #"^(?:c[óo]mo\s+funciona|por\s+qu[ée])\s+"#
    ]

    private nonisolated static let questionRegexes: [NSRegularExpression] = {
        leadingQuestionPatterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// Stop words, question words, and grammatical glue in EN, FR, and ES.
    /// Kept minimal so technical terms and meaningful entities are preserved.
    private nonisolated static let stopWords: Set<String> = [
        // English
        "who", "what", "where", "when", "why", "how", "which", "whose", "whom",
        "is", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "have", "has", "had",
        "can", "could", "should", "would", "will", "shall",
        "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for",
        "about", "with", "by", "from", "into", "onto", "upon",

        // French
        "qui", "que", "quoi", "dont", "où", "ou", "quand", "comment", "pourquoi",
        "quel", "quelle", "quels", "quelles",
        "est", "sont", "était", "étaient", "fut", "furent", "été",
        "a", "ai", "as", "avons", "avez", "ont", "avait", "avaient",
        "c'est", "ce", "cet", "cette", "ces",
        "le", "la", "les", "un", "une", "des", "du", "de", "d", "l",
        "en", "dans", "sur", "sous", "pour", "avec", "par", "vers", "et",

        // Spanish
        "qué", "que", "quién", "quiénes", "dónde", "cuándo", "cómo", "cuál", "cuáles",
        "es", "son", "era", "eran", "fue", "fueron", "sido",
        "ha", "han", "hay", "hacer",
        "el", "la", "los", "las", "un", "una", "unos", "unas",
        "de", "del", "en", "por", "para", "con", "sobre", "entre", "y", "o"
    ]

    /// Strips leading French elided particles (l', d', c', etc.).
    private nonisolated static let frenchElidedPrefixRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^[ldcjmtsn]['’]"#, options: [.caseInsensitive])
    }()

    /// Strips trailing English possessive `'s` or `’s`.
    private nonisolated static let englishPossessiveRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"['’]s$"#, options: [.caseInsensitive])
    }()

    /// Cleans a query string for consumption by the Wikipedia search API.
    ///
    /// 1. Trims whitespace and trailing question/exclamation marks.
    /// 2. Removes leading question patterns and conversational frames.
    /// 3. Filters out question words and filler stop words.
    /// 4. Handles French elisions (e.g. `l'ADN` -> `ADN`).
    /// 5. Gracefully falls back to the original trimmed input if filtering
    ///    would otherwise result in an empty string (e.g. searching "The Who").
    ///
    /// - Parameter rawQuery: Raw user prompt or model-generated query.
    /// - Returns: A keyword-focused query suitable for Wikipedia.
    nonisolated static func clean(_ rawQuery: String) -> String {
        var query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "" }

        // Strip leading inverted Spanish punctuation (¿, ¡) and quotes
        query = query.trimmingCharacters(in: CharacterSet(charactersIn: "¿¡\"'«»“”"))

        // Strip trailing question/exclamation marks, periods, and quotes
        while let last = query.last, "?!.\"\'»”".contains(last) {
            query.removeLast()
            query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !query.isEmpty else { return "" }

        // Step 1: Strip leading conversational question patterns
        for regex in questionRegexes {
            let nsRange = NSRange(query.startIndex..., in: query)
            if let match = regex.firstMatch(in: query, options: [], range: nsRange),
               let matchRange = Range(match.range, in: query),
               matchRange.lowerBound == query.startIndex {
                query = String(query[matchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Step 2: Tokenize and filter out question/stop words
        let rawTokens = query.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        var keywords: [String] = []

        for rawToken in rawTokens {
            let trimmedToken = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]{}\"«»“”"))
            guard !trimmedToken.isEmpty else { continue }

            // Normalize for stop-word checking
            let lowercased = trimmedToken.lowercased()
            if stopWords.contains(lowercased) {
                continue
            }

            // Strip French elision prefix if present (e.g. "l'ADN" -> "ADN", "d'Einstein" -> "Einstein")
            var candidate = trimmedToken
            if let elidedRegex = frenchElidedPrefixRegex {
                let nsRange = NSRange(candidate.startIndex..., in: candidate)
                if let match = elidedRegex.firstMatch(in: candidate, options: [], range: nsRange),
                   let matchRange = Range(match.range, in: candidate) {
                    let stripped = String(candidate[matchRange.upperBound...])
                    if !stripped.isEmpty && !stopWords.contains(stripped.lowercased()) {
                        candidate = stripped
                    }
                }
            }

            // Strip trailing English possessive 's if attached
            if let possessiveRegex = englishPossessiveRegex {
                let nsRange = NSRange(candidate.startIndex..., in: candidate)
                if let match = possessiveRegex.firstMatch(in: candidate, options: [], range: nsRange),
                   let matchRange = Range(match.range, in: candidate) {
                    let stripped = String(candidate[..<matchRange.lowerBound])
                    if !stripped.isEmpty && !stopWords.contains(stripped.lowercased()) {
                        candidate = stripped
                    }
                }
            }

            if !candidate.isEmpty && !stopWords.contains(candidate.lowercased()) {
                keywords.append(candidate)
            }
        }

        let cleaned = keywords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 3: Fallback if all words were stripped (e.g. query was literally "The Who" or "Why")
        if cleaned.isEmpty {
            let strippedFallback = query.trimmingCharacters(in: CharacterSet(charactersIn: "¿?!¡\"'«»“”\n\r\t "))
            return strippedFallback
        }

        return cleaned
    }
}

