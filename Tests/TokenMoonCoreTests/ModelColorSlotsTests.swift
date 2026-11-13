// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import TokenMoonCore

@Test func modelColorSlotsSurviveFilteringAndNewModels() {
    let first = ModelColorSlots.adding(["gpt-5", "claude-sonnet", "gemini-pro"], to: [:])
    let filtered = ModelColorSlots.adding(["gemini-pro"], to: first)
    let restarted = ModelColorSlots.validated(filtered)
    let newModel = ModelColorSlots.adding(["a-new-model", "gemini-pro"], to: restarted)
    #expect(first == filtered)
    #expect(first.allSatisfy { newModel[$0.key] == $0.value })
    #expect(Set(newModel.values).count == 4)
}
