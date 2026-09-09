//
//  WikipediaQueryCleanerTests.swift
//  SilicIATests
//
//  Unit tests for WikipediaQueryCleaner, validating that question words,
//  conversational frames, and stop words are stripped while key entities
//  and technical terms are preserved across English, French, and Spanish.
//

import XCTest
@testable import SilicIA

final class WikipediaQueryCleanerTests: XCTestCase {

    // MARK: - English Query Tests

    func testEnglishQuestionWordsStripped() {
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Who was the first president of the United States?"),
            "first president United States"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("What is photosynthesis?"),
            "photosynthesis"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Where is the Eiffel Tower located?"),
            "Eiffel Tower located"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("When was Apollo 11 launched?"),
            "Apollo 11 launched"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Why does the moon have phases?"),
            "moon phases"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("How does an airplane fly?"),
            "airplane fly"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("How to bake sourdough bread?"),
            "bake sourdough bread"
        )
    }

    func testEnglishConversationalFluffStripped() {
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Can you tell me about quantum computing?"),
            "quantum computing"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Tell me about Albert Einstein"),
            "Albert Einstein"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Explain the theory of general relativity."),
            "theory general relativity"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Information on NASA Artemis program"),
            "NASA Artemis program"
        )
    }

    // MARK: - French Query Tests

    func testFrenchQuestionWordsStripped() {
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Qu'est-ce que la relativité générale ?"),
            "relativité générale"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("C'est quoi l'intelligence artificielle ?"),
            "intelligence artificielle"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Qui est Marie Curie ?"),
            "Marie Curie"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Qui a découvert la pénicilline ?"),
            "découvert pénicilline"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Où se trouve la Tour Eiffel ?"),
            "Tour Eiffel"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Comment fonctionne l'ADN ?"),
            "ADN"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Pourquoi le ciel est bleu ?"),
            "ciel bleu"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Quel est le plus haut sommet du monde ?"),
            "plus haut sommet monde"
        )
    }

    func testFrenchConversationalFluffStripped() {
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Peux-tu m'expliquer la photosynthèse ?"),
            "photosynthèse"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Dis-moi qui est Victor Hugo"),
            "Victor Hugo"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Donne-moi des infos sur Napoléon Bonaparte"),
            "Napoléon Bonaparte"
        )
    }

    func testFrenchElisionHandling() {
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("l'astronomie moderne"),
            "astronomie moderne"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("théorie d'Einstein"),
            "théorie Einstein"
        )
    }

    // MARK: - Spanish Query Tests

    func testSpanishQuestionWordsStripped() {
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("¿Quién fue Simón Bolívar?"),
            "Simón Bolívar"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("¿Qué es la fotosíntesis?"),
            "fotosíntesis"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("¿Dónde está la Alhambra?"),
            "Alhambra"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("¿Cómo funciona un motor eléctrico?"),
            "motor eléctrico"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("¿Cuándo ocurrió la Revolución Francesa?"),
            "Revolución Francesa"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("¿Cuál es la capital de Australia?"),
            "capital Australia"
        )
    }

    // MARK: - Edge Cases & Fallback

    func testFallbackWhenAllWordsAreStopWords() {
        // Queries like "The Who" or "Why" should not collapse to empty string
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("The Who"),
            "The Who"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("Why?"),
            "Why"
        )
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(WikipediaQueryCleaner.clean(""), "")
        XCTAssertEqual(WikipediaQueryCleaner.clean("   "), "")
        XCTAssertEqual(WikipediaQueryCleaner.clean("???"), "")
    }

    func testPunctuationAndQuotesStripping() {
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("\"James Webb Space Telescope\"?"),
            "James Webb Space Telescope"
        )
        XCTAssertEqual(
            WikipediaQueryCleaner.clean("« Tour Eiffel »!"),
            "Tour Eiffel"
        )
    }

    func testIdempotence() {
        let query = "Who was the first president of the United States?"
        let cleanedOnce = WikipediaQueryCleaner.clean(query)
        let cleanedTwice = WikipediaQueryCleaner.clean(cleanedOnce)
        XCTAssertEqual(cleanedOnce, cleanedTwice)
    }
}

