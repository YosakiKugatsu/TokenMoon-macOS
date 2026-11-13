// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private struct CodexCounts: Equatable, Hashable {
    let input: Int64
    let output: Int64
    let read: Int64
    let write: Int64
    let reasoning: Int64?

    init?(_ value: CollectorJSON?) {
        guard let value, let input = value.number("input_tokens"), let output = value.number("output_tokens") else { return nil }
        let read = value.number("cached_input_tokens") ?? 0
        let write = value.number("cache_write_input_tokens") ?? 0
        guard read + write <= input else { return nil }
        self.input = input
        self.output = output
        self.read = read
        self.write = write
        reasoning = value.number("reasoning_output_tokens").flatMap { $0 <= output ? $0 : nil }
    }

    var hasTokens: Bool { input > 0 || output > 0 }

    func includes(_ other: Self) -> Bool {
        input >= other.input && output >= other.output && read >= other.read && write >= other.write
    }

    func matches(_ other: Self) -> Bool {
        input == other.input && output == other.output && read == other.read && write == other.write
    }
}

private struct CodexContext {
    var model: String?
    var effort: String?
    var requestedTier: String?
    var provider: String?
}

private struct CodexLegacyInterval: Hashable {
    let turn: String?
    let total: CodexCounts
}

private struct CodexTurnEstimate {
    private var boundary: Date?
    private var answerStart: Date?
    private var lastAnswer: Date?

    mutating func input(at: Date) {
        if boundary.map({ at > $0 }) ?? true { boundary = at }
    }

    mutating func answer(at: Date) {
        if lastAnswer == nil { answerStart = boundary }
        if lastAnswer.map({ at > $0 }) ?? true { lastAnswer = at }
    }

    mutating func finish(at: Date) -> Double? {
        var end = at
        // A tool result may already be logged before the usage record for
        // the response that requested it. Keep that result for the next call.
        if let lastAnswer, let boundary, lastAnswer < boundary, boundary <= at {
            end = lastAnswer
        }
        let start = lastAnswer == nil ? boundary : answerStart
        self.lastAnswer = nil
        answerStart = nil
        input(at: end)
        return sessionIntervalMS(from: start, to: end)
    }
}

func collectCodex(_ file: URL, device: String, authByTurn: [CodexAuthTurn: CodexAuthEvidence] = [:]) throws -> [UsageRequest] {
    var sourceThreadID: String?
    var sourceCreator: CodexCreatorIdentity?
    return try collectCodex(file, device: device, authByTurn: authByTurn, sourceThreadID: &sourceThreadID, sourceCreator: &sourceCreator)
}

func collectCodex(_ file: URL, device: String, authByTurn: [CodexAuthTurn: CodexAuthEvidence],
                  sourceThreadID: inout String?, sourceCreator: inout CodexCreatorIdentity?) throws -> [UsageRequest] {
    let dates = CollectorDates()
    var rows: [String: UsageRequest] = [:]
    var session: String?
    var thread: String?
    var sessionStarted: Date?
    var creatorAccountID: String?
    var creator: CodexCreatorIdentity?
    var provider: String?
    var inheritedHistory = false
    var inheritedHistoryEnd: Int64 = 0
    var currentTurn: String?
    var contexts: [String: CodexContext] = [:]
    var settings: CodexContext = .init()
    var previousTotal: CodexCounts?
    var pending: (turn: String?, counts: CodexCounts)?
    var seenLegacy: Set<CodexLegacyInterval> = []
    var epoch = 0
    var estimate = CodexTurnEstimate()
    var activeTimingTurn: String?
    var precedingContextWithoutTier: (turn: String, line: Int)?

    func makeRequest(_ row: CollectorJSON, session: String, at: Date, counts: CodexCounts,
                     id: String, context: CodexContext, turn: String?, legacy: Bool = false, interval: Double? = nil) -> UsageRequest {
        let (duration, timing) = requestTiming(row, dates: dates)
        let providerID = row.text("model_provider") ?? context.provider ?? provider
        let estimated = duration == nil ? interval : nil
        let observedLogin = row.text("login_method") ?? row.text("auth_mode") ?? row.text("auth_type")
        let turnLogin: CodexAuthEvidence? = if observedLogin == nil, let thread, let turn {
            authByTurn[CodexAuthTurn(threadID: thread, turnID: turn)]
        } else { nil }
        let login: String?
        let loginEvidence: LoginMethodEvidence?
        switch turnLogin {
        case .method(let method): (login, loginEvidence) = (method, .turnTrace)
        case .ambiguous: (login, loginEvidence) = (nil, .conflicting)
        case nil: (login, loginEvidence) = (observedLogin, nil)
        }
        return UsageRequest(id: id, sessionID: session, deviceID: device, agent: .codex, timestamp: at,
                            requestedModel: row.text("requested_model") ?? row.text("model") ?? context.model ?? "unknown",
                            sentModel: row.text("sent_model") ?? row.text("response_model"),
                            provider: row.text("provider") ?? providerID, providerID: providerID,
                            account: row.text("account") ?? row.text("session_account"),
                            loginMethod: login,
                            reasoningEffort: row.text("reasoning_effort") ?? context.effort,
                            serviceTier: collectorTier(row.text("service_tier_served") ?? row.text("actual_service_tier") ?? row.text("service_tier")),
                            requestedServiceTier: collectorTier(row.text("requested_service_tier")) ?? context.requestedTier,
                            status: "success", durationMS: duration, timingSource: timing,
                            estimatedDurationMS: estimated, estimatedTimingSource: estimated == nil ? nil : "codex-session-log",
                            inputTokens: counts.input - counts.read - counts.write, outputTokens: counts.output,
                            cacheReadTokens: counts.read, cacheWriteTokens: counts.write, reasoningTokens: counts.reasoning,
                            source: legacy ? "codex.token_count" : "codex.token_usage_record", channel: row.text("channel"),
                            sessionCreatorAccountID: creatorAccountID, loginMethodEvidence: loginEvidence)
    }

    func observeResponse(_ row: CollectorJSON, at: Date, compaction: Bool) {
        guard let session, let response = row.text("response_id"),
              (row.text("session_id") ?? session) == session,
              row.text("thread_id").map({ $0 == thread }) ?? true,
              let counts = CodexCounts(row.dict("usage")), counts.hasTokens else { return }
        let turn = row.text("turn_id") ?? currentTurn
        let context = turn.flatMap { contexts[$0] } ?? settings
        let id = collectorID("codex", session, response)
        let interval: Double? = if !compaction, rows[id] == nil, let turn, turn == activeTimingTurn {
            estimate.finish(at: at)
        } else { nil }
        let new = makeRequest(row, session: session, at: at, counts: counts, id: id, context: context,
                              turn: turn, interval: interval)
        if let old = rows[id] {
            // The same response can be serialized in a compaction snapshot and
            // as a top-level event. Keep the original occurrence with metadata.
            if new.timestamp < old.timestamp || (old.durationMS == nil && new.durationMS != nil)
                || (old.requestedModel == "unknown" && new.requestedModel != "unknown") {
                rows[id] = new.preservingEvidence(from: old)
            } else {
                rows[id] = old.preservingEvidence(from: new)
            }
        } else {
            rows[id] = new
        }
        if !compaction {
            pending = (turn, counts)
        }
    }

    try readNumberedCollectorLines(file, markers: ["\"session_meta\"", "\"turn_context\"", "\"token_usage_record\"",
                                          "\"token_count\"", "\"compacted\"", "\"thread_settings_applied\"",
                                          "\"task_started\"", "\"task_complete\"", "\"turn_aborted\"", "\"user_message\"",
                                          "\"user\"", "\"assistant\"", "\"reasoning\"", "\"function_call\"",
                                          "\"function_call_output\"", "\"custom_tool_call\"", "\"custom_tool_call_output\"",
                                          "\"web_search_call\"", "\"local_shell_call\"", "\"tool_search_call\"",
                                          "\"tool_search_output\"", "\"image_generation_call\""]) { item, line in
        let pairedContext = precedingContextWithoutTier
        precedingContextWithoutTier = nil
        guard let type = item.text("type"), let row = item.dict("payload"),
              let at = dates.parse(item.text("timestamp")) else { return }
        // Codex can replay the parent's prefix with fresh timestamps in a
        // subagent log. Its recorded boundary counts physical rollout lines.
        guard Int64(line) > inheritedHistoryEnd else { return }
        switch type {
        case "session_meta":
            if session == nil {
                session = row.text("session_id") ?? row.text("id")
                thread = row.text("id") ?? session
                provider = row.text("model_provider")
                sessionStarted = dates.parse(row.text("timestamp")) ?? at
                // Codex preserves the creator when a different account resumes the thread.
                creatorAccountID = row.text("creator_account_id").flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
                creator = CodexCreatorIdentity(userID: row.text("creator_user_id"), accountID: creatorAccountID)
                inheritedHistoryEnd = row.number("subagent_history_start_ordinal") ?? 0
                inheritedHistory = row.text("forked_from_id") != nil || inheritedHistoryEnd > 0
                settings.provider = provider
            }
        case "turn_context":
            let turn = row.text("turn_id") ?? currentTurn
            if turn != currentTurn { pending = nil }
            if turn != currentTurn, let turn {
                estimate = CodexTurnEstimate()
                activeTimingTurn = turn
            }
            currentTurn = turn
            guard let turn else { return }
            var context = contexts[turn] ?? settings
            context.model = row.text("model") ?? context.model
            context.effort = row.text("effort") ?? row.text("reasoning_effort") ?? context.effort
            let explicitTier = collectorTier(row.text("service_tier"))
            context.requestedTier = explicitTier ?? context.requestedTier
            context.provider = row.text("model_provider") ?? context.provider
            contexts[turn] = context
            if explicitTier == nil { precedingContextWithoutTier = (turn, line) }
        case "token_usage_record":
            if inheritedHistory, let sessionStarted, at < sessionStarted { return }
            observeResponse(row, at: at, compaction: false)
        case "compacted":
            if inheritedHistory, let sessionStarted, at <= sessionStarted { return }
            if let latest = row.dict("latest_token_usage_record"),
               let response = row.text("compaction_response_id"), latest.text("response_id") == response {
                observeResponse(latest, at: at, compaction: true)
            }
            // A snapshot is not a response timestamp. Do not span its hidden
            // work with an interval carried from an earlier request.
            estimate = CodexTurnEstimate()
        case "response_item":
            guard activeTimingTurn != nil, activeTimingTurn == currentTurn,
                  !inheritedHistory || sessionStarted.map({ at >= $0 }) == true else { return }
            switch row.text("type") {
            case "function_call_output", "custom_tool_call_output", "tool_search_output":
                estimate.input(at: at)
            case "message" where row.text("role") == "user":
                estimate.input(at: at)
            case "message" where row.text("role") == "assistant":
                estimate.answer(at: at)
            case "reasoning", "function_call", "custom_tool_call", "web_search_call",
                 "local_shell_call", "tool_search_call", "image_generation_call":
                estimate.answer(at: at)
            default: break
            }
        case "event_msg":
            switch row.text("type") {
            case "thread_settings_applied":
                let settingsThread = row.text("thread_id")
                // A subagent writes usage to the parent session, but its
                // service tier belongs to the thread running that request.
                guard let config = row.dict("thread_settings"),
                      settingsThread == nil || settingsThread == thread else { return }
                settings = CodexContext(model: config.text("model") ?? settings.model,
                                        effort: config.text("reasoning_effort"),
                                        requestedTier: collectorTier(config.text("service_tier")),
                                        provider: config.text("model_provider_id") ?? provider)
                // New Codex writes its initial turn context and effective settings
                // as adjacent rollout records. Only use this pair to fill the
                // missing current-turn tier; standalone settings apply to later turns.
                if let pairedContext, pairedContext.line == line - 1,
                   pairedContext.turn == currentTurn, settingsThread != nil,
                   var context = contexts[pairedContext.turn],
                   context.model == nil || context.model == settings.model,
                   let tier = settings.requestedTier {
                    context.requestedTier = tier
                    contexts[pairedContext.turn] = context
                }
            case "task_started":
                pending = nil
                currentTurn = row.text("turn_id")
                estimate = CodexTurnEstimate()
                activeTimingTurn = currentTurn
                if activeTimingTurn != nil, !inheritedHistory || sessionStarted.map({ at >= $0 }) == true {
                    estimate.input(at: at)
                }
                if let turn = currentTurn, contexts[turn] == nil {
                    var context = settings
                    context.model = row.text("model") ?? context.model
                    contexts[turn] = context
                }
            case "task_complete", "turn_aborted":
                pending = nil
                currentTurn = nil
                activeTimingTurn = nil
                estimate = CodexTurnEstimate()
            case "user_message":
                if activeTimingTurn != nil, activeTimingTurn == currentTurn,
                   !inheritedHistory || sessionStarted.map({ at >= $0 }) == true {
                    estimate.input(at: at)
                }
            case "token_count":
                guard let session, let info = row.dict("info"),
                      let total = CodexCounts(info.dict("total_token_usage")) else { return }
                let previous = previousTotal
                previousTotal = total
                guard let last = CodexCounts(info.dict("last_token_usage")), last.hasTokens, total.includes(last) else { return }
                if inheritedHistory, let sessionStarted, at <= sessionStarted { pending = nil; return }
                if let previous, total.matches(previous) { return } // repeated checkpoint
                if let previous, !total.includes(previous) { epoch += 1; seenLegacy.removeAll(keepingCapacity: true) }
                let interval = CodexLegacyInterval(turn: currentTurn, total: total)
                guard seenLegacy.insert(interval).inserted else { return }
                defer { pending = nil }
                // Current logs emit a response record then its compatibility
                // token_count checkpoint. Match within the same turn and counts.
                if let pending, pending.turn == currentTurn, pending.counts.matches(last) { return }
                let identity = collectorID("codex-legacy", session, currentTurn ?? "", String(epoch),
                                           String(total.input), String(total.output), String(total.read), String(total.write))
                let context = currentTurn.flatMap { contexts[$0] } ?? settings
                let elapsed = currentTurn != nil && currentTurn == activeTimingTurn ? estimate.finish(at: at) : nil
                rows[identity] = makeRequest(row, session: session, at: at, counts: last,
                                             id: identity, context: context, turn: currentTurn, legacy: true, interval: elapsed)
            default: break
            }
        default: break
        }
    }
    sourceThreadID = thread
    sourceCreator = creator
    return Array(rows.values)
}
