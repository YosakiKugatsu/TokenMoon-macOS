// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Suite("Presentation names preserve provider and model identity")
struct ModelNamesTests {
    @Test func prefersDirectProviderAndDoesNotGuessAnAmbiguousBareID() throws {
        let catalog = try ModelNames.decode(Data(#"""
        {
          "openai": {"models": {
            "gpt-6.1-sol": {"id": "gpt-6.1-sol", "name": "GPT-6.1 Sol"},
            "codex-preview": {"name": "Codex Preview", "cost": {}}
          }},
          "gateway-a": {"models": {
            "gpt-6.1-sol": {"name": "Other GPT Name"},
            "custom": {"name": "Custom Model A"}
          }},
          "gateway-b": {"models": {
            "custom": {"name": "Custom Model B"},
            "with-control": {"name": "Bad\nTitle"},
            "mismatch": {"id": "another-id", "name": "Unrelated Name"}
          }}
        }
        """#.utf8))
        #expect(catalog.displayName(for: "gpt-6.1-sol") == "GPT-6.1 Sol")
        #expect(catalog.displayName(for: "gateway-a/gpt-6.1-sol") == "Other GPT Name")
        #expect(catalog.displayName(for: "codex-preview") == "Codex Preview")
        #expect(catalog.displayName(for: "custom") == "Custom")
        #expect(catalog.displayName(for: "gateway-b/custom") == "Custom Model B")
        #expect(catalog.displayName(for: "with-control") == "With Control")
        #expect(catalog.displayName(for: "mismatch") == "Mismatch")
    }

    @Test func offlineFallbackKeepsVersionAndQuantization() {
        let offline = ModelNames.empty
        #expect(offline.displayName(for: "gpt-6.1-sol") == "GPT-6.1 Sol")
        #expect(offline.displayName(for: "claude-opus-5-5") == "Claude Opus 5.5")
        #expect(offline.displayName(for: "claude-3-5-sonnet-20241022") == "Claude Sonnet 3.5 (20241022)")
        #expect(offline.displayName(for: "gemini-3.1-pro-preview") == "Gemini 3.1 Pro Preview")
        #expect(offline.displayName(for: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_XXS") == "Qwen3.8 Flash Next GSQ RCO GGUF · IQ3_XXS")
        #expect(offline.displayName(for: "codex-auto-review") == "Codex Auto Review")
        #expect(offline.displayName(for: "unknown") == "未知模型")
    }

    @Test func refreshCanPersistIndependentlyAndRoundTrip() throws {
        let old = try ModelNames.decode(Data(#"{"names":{"old":"Old Display Name","refresh":"Before"}}"#.utf8))
        let new = try ModelNames.decode(Data(#"{"names":{"refresh":"After"}}"#.utf8))
        let reloaded = try ModelNames.decode(old.merging(new).encoded())
        #expect(reloaded.count == 2)
        #expect(reloaded.displayName(for: "old") == "Old Display Name")
        #expect(reloaded.displayName(for: "refresh") == "After")
        #expect(throws: (any Error).self) { try ModelNames.decode(Data(#"{"names":{}}"#.utf8)) }
    }

    @Test func bundledCatalogHasVerifiedDisplayNames() throws {
        let catalog = try ModelNames.bundled()
        #expect(catalog.count > 100)
        #expect(catalog.displayName(for: "gpt-6.1-sol") == "GPT-6.1 Sol")
        #expect(catalog.displayName(for: "claude-opus-5-5") == "Claude Opus 5.5")
    }
}
