// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private struct ClaudeCounts: Hashable {
    let input: Int64
    let output: Int64
    let read: Int64
    let write: Int64
    let reason: Int64?

    init?(_ usage: CollectorJSON?) {
        guard let usage, let input = usage.number("input_tokens"), let output = usage.number("output_tokens") else { return nil }
        self.input = input
        self.output = output
        self.read = usage.number("cache_read_input_tokens") ?? 0
        let ttl = usage.dict("cache_creation")
        let split = (ttl?.number("ephemeral_5m_input_tokens") ?? 0) + (ttl?.number("ephemeral_1h_input_tokens") ?? 0)
        self.write = max(split, usage.number("cache_creation_input_tokens") ?? 0)
        self.reason = (usage.dict("output_tokens_details")?.number("thinking_tokens")
                      ?? usage.number("reasoning_tokens")).flatMap { $0 <= output ? $0 : nil }
    }
}

private struct ClaudeStream: Hashable {
    let session: String
    let branch: String?
}

private struct ClaudeMessageIdentity: Hashable {
    let agent: Agent
    let session: String
    let messageID: String

    var ledgerID: String { collectorID(agent.rawValue, session, "message", messageID) }
    func requestLedgerID(_ id: String) -> String { collectorID(agent.rawValue, session, "request", id) }
}

private struct ClaudeTurn: Hashable {
    let stream: ClaudeStream
    let sequence: Int
}

private struct ClaudePromptState {
    var sequence = 0
    var input: Date?
}

private struct ClaudeInterval {
    let turn: ClaudeTurn
    let start: Date?
    var end: Date
    var blocks: Set<String>
}

private struct ClaudeObservation {
    let date: Date
    let agent: Agent
    let session: String
    let request: String?
    let message: String?
    let model: String
    let sent: String?
    let provider: String?
    let providerID: String?
    let account: String?
    let login: String?
    let effort: String?
    let tier: String?
    let requestedTier: String?
    let failed: Bool
    let httpStatusCode: Int?
    let failureMessage: String?
    let duration: Double?
    let timing: String?
    let counts: ClaudeCounts?
    let cache5m: Int64?
    let cache1h: Int64?
    let channel: String?
    let turn: ClaudeTurn
    let input: Date?
    let uuid: String?
    let parentUUID: String?
}

func collectClaude(
    _ file: URL, device: String, agent: Agent, titles: inout [String: SessionTitleEvidence],
    aliasClaims: inout [String: Set<String>]
) throws -> [UsageRequest] {
    let dates = CollectorDates()
    var observations: [ClaudeObservation] = []
    var requestsByMessage: [ClaudeMessageIdentity: Set<String>] = [:]
    var successfulLinks: Set<ClaudeMessageIdentity> = []
    var prompts: [ClaudeStream: ClaudePromptState] = [:]
    var nativeTitles: [String: SessionTitleEvidence] = [:]
    let hasMainTitles = !file.pathComponents.contains("subagents")
    try readCollectorLines(file, markers: ["\"assistant\"", "\"user\"", "\"turn_duration\"", "\"compact_boundary\"", "\"api_error\"",
                                          "\"custom-title\"", "\"ai-title\""]) { row in
        guard let type = row.text("type"), let session = row.text("sessionId") ?? row.text("session_id") else { return }
        if type == "custom-title" || type == "ai-title" {
            let custom = type == "custom-title"
            guard hasMainTitles, (row["isSidechain"] as? Bool) != true,
                  let label = explicitSessionTitle(row[custom ? "customTitle" : "aiTitle"]) else { return }
            let title = SessionTitleEvidence(title: label, priority: custom ? 2 : 1, updatedAt: dates.parse(row.text("timestamp")))
            putSessionTitle(title, for: session, in: &nativeTitles)
            return
        }
        guard let at = dates.parse(row.text("timestamp")) else { return }
        let branch = (row["isSidechain"] as? Bool) == true ? (row.text("agentId") ?? "sidechain") : nil
        let stream = ClaudeStream(session: session, branch: branch)
        var prompt = prompts[stream] ?? ClaudePromptState()
        if type == "system", ["turn_duration", "compact_boundary", "api_error"].contains(row.text("subtype") ?? "") {
            // Never bridge pauses between user turns or compaction gaps.
            prompt.sequence += 1
            prompt.input = nil
            prompts[stream] = prompt
            return
        }
        if type == "user" {
            guard (row["isMeta"] as? Bool) != true, (row["isCompactSummary"] as? Bool) != true,
                  row.dict("message")?.text("role") != "assistant" else { return }
            if prompt.input.map({ at >= $0 }) ?? true { prompt.input = at }
            prompts[stream] = prompt
            return
        }
        guard type == "assistant" else { return }
        let message = row.dict("message") ?? [:]
        let apiError = row.dict("apiError")
        let params = row.dict("apiErrorParams")
        let statusCode = collectorHTTPStatus(row) ?? collectorHTTPStatus(apiError) ?? collectorHTTPStatus(params)
        let model = collectorRecordedModel(message.text("model"))
        let failed = (row["isApiErrorMessage"] as? Bool) == true || message.text("model") == "<synthetic>"
            || statusCode.map { $0 >= 400 } == true
        guard failed || model != nil else { return }
        let source: Agent = row.text("entrypoint") == "claude-desktop" ? .claudeDesktop : agent
        let requestID = row.text("requestId") ?? row.text("request_id")
        let messageID = message.text("id")
        if let requestID, let messageID {
            let identity = ClaudeMessageIdentity(agent: source, session: session, messageID: messageID)
            requestsByMessage[identity, default: []].insert(requestID)
            if !failed { successfulLinks.insert(identity) }
        }
        let usage = message.dict("usage")
        let counts = ClaudeCounts(usage)
        if !failed, counts == nil { return }
        let providerID = row.text("provider_id") ?? row.text("providerId")
        let (ownDuration, ownTiming) = requestTiming(row, dates: dates)
        let (messageDuration, messageTiming) = requestTiming(message, dates: dates)
        let ttl = usage?.dict("cache_creation")
        let requestedModel = collectorRecordedModel(row.text("requestedModel") ?? row.text("requested_model"))
            ?? model ?? (failed ? collectorRecordedModel(params?.text("model") ?? apiError?.text("model")) : nil)
        let failureMessage = failed ? (collectorFailureMessage(params?["message"])
            ?? collectorFailureMessage(row["apiError"])
            ?? collectorFailureMessage(row["errorMessage"]) ?? collectorFailureMessage(row["error_message"])
            ?? collectorFailureMessage(row["error"])) : nil
        // Anthropic's usage.service_tier names a capacity tier, not speed.
        observations.append(ClaudeObservation(date: at, agent: source, session: session, request: requestID,
            message: messageID, model: requestedModel ?? "unknown", sent: model,
            provider: row.text("provider") ?? providerID, providerID: providerID,
            account: row.text("account") ?? row.text("sessionAccount"), login: row.text("login_method") ?? row.text("loginMethod"),
            effort: row.text("perTurnEffort") ?? row.text("effort"), tier: collectorTier(usage?.text("speed")),
            requestedTier: collectorTier(row.text("requestedServiceTier") ?? row.text("requested_service_tier")
                ?? row.text("requestedSpeed") ?? row.text("requested_speed")),
            failed: failed, httpStatusCode: statusCode, failureMessage: failureMessage,
            duration: ownDuration ?? messageDuration, timing: ownTiming ?? messageTiming, counts: counts,
            cache5m: ttl?.number("ephemeral_5m_input_tokens"), cache1h: ttl?.number("ephemeral_1h_input_tokens"), channel: row.text("channel"),
            turn: ClaudeTurn(stream: stream, sequence: prompt.sequence), input: prompt.input,
            uuid: row.text("uuid"), parentUUID: row.text("parentUuid")))
    }

    // Preserve even ambiguous claims to prevent two copied files from silently
    // asserting different canonical IDs for the same provisional request.
    var ledgerRequestIDs: [ClaudeMessageIdentity: Set<String>] = [:]
    var claimCounts: [String: Int] = [:]
    for (identity, requests) in requestsByMessage {
        let candidates = Set(requests.map(identity.requestLedgerID))
        ledgerRequestIDs[identity] = candidates
        aliasClaims[identity.ledgerID, default: []].formUnion(candidates)
        for candidate in candidates { claimCounts[candidate, default: 0] += 1 }
    }

    // A streamed reply logs several blocks. Replayed usage snapshots do not
    // add requests or roll back the accepted token counts of the same message.
    struct Revision {
        let request: UsageRequest
        let observedAt: Date
        let counts: ClaudeCounts?
        let previous: Set<ClaudeCounts>
        let interval: ClaudeInterval
    }
    var rows: [String: Revision] = [:]
    var lastReply: [ClaudeTurn: String] = [:]
    for observation in observations {
        let at = observation.date
        let source = observation.agent
        let session = observation.session
        let message = observation.message.map { ClaudeMessageIdentity(agent: source, session: session, messageID: $0) }
        let explicit = observation.request.map { collectorID(source.rawValue, session, "request", $0) }
        let mapped = message.flatMap { identity -> String? in
            guard successfulLinks.contains(identity), let candidates = ledgerRequestIDs[identity], candidates.count == 1,
                  let candidate = candidates.first, claimCounts[candidate] == 1 else { return nil }
            return candidate
        }
        let canonicalID = explicit ?? mapped
        let failed = observation.failed
        // A synthetic error without a provider request ID isn't evidence that
        // an upstream request ran (can be local cancellation or auth failure).
        if failed, canonicalID == nil { continue }
        guard let id = canonicalID ?? message?.ledgerID else { continue }
        let counts = observation.counts
        let old = rows[id]
        let tierConflict = old?.request.actualServiceTierEvidence == .conflicting
            || (!failed && old?.request.isFailure == false && old?.request.modelIdentity == (observation.sent ?? observation.model)
                && old?.request.serviceTier != nil && observation.tier != nil && old?.request.serviceTier != observation.tier)
        if let old {
            let replayedCounts = counts.map { old.previous.contains($0) && $0 != old.counts } ?? false
            if (!failed && at < old.observedAt) || (failed && !old.request.isFailure) || replayedCounts {
                if tierConflict && old.request.actualServiceTierEvidence == nil {
                    var conflicted = old.request
                    conflicted.actualServiceTierEvidence = .conflicting
                    conflicted.serviceTier = nil
                    rows[id] = Revision(request: conflicted, observedAt: old.observedAt, counts: old.counts,
                                        previous: old.previous, interval: old.interval)
                }
                continue
            }
        }
        var previous = old?.previous ?? []
        if let oldCounts = old?.counts { previous.insert(oldCounts) }
        let previousReply = lastReply[observation.turn].flatMap { rows[$0] }
        let sameTurn = old?.interval.turn == observation.turn
        let followedByInput = if let old, let input = observation.input { input > old.interval.end } else { false }
        var interval: ClaudeInterval
        if let old {
            interval = old.interval
            // Repeated revisions must not turn elapsed idle time into a longer
            // estimate. A new block ID or accepted usage revision is evidence.
            let newBlock = observation.uuid.map { !interval.blocks.contains($0) } ?? false
            if sameTurn && !followedByInput && !failed && (newBlock || counts != old.counts) {
                interval.end = max(interval.end, at)
                if let uuid = observation.uuid { interval.blocks.insert(uuid) }
            }
        } else {
            let input = observation.input.flatMap { value -> Date? in
                guard value < at, previousReply.map({ value >= $0.interval.end }) ?? true else { return nil }
                return value
            }
            // Without a fresh prompt/tool result, require a transcript link to
            // the preceding response before using its timestamp as a boundary.
            let linkedReplyEnd = observation.parentUUID.flatMap { parent -> Date? in
                guard let previousReply, previousReply.request.agent == source,
                      !previousReply.request.isFailure, previousReply.interval.blocks.contains(parent),
                      previousReply.interval.end < at else { return nil }
                return previousReply.interval.end
            }
            interval = ClaudeInterval(turn: observation.turn, start: input ?? linkedReplyEnd, end: at,
                                      blocks: Set([observation.uuid].compactMap { $0 }))
        }
        let duration = observation.duration ?? old?.request.durationMS
        let estimated = duration == nil && !failed ? sessionIntervalMS(from: interval.start, to: interval.end) : nil
        let requestedModel = collectorRecordedModel(observation.model) ?? old?.request.requestedModel ?? "unknown"
        // Revisions of the same request may add actual error metadata. Never
        // carry a prior error into a successful revision.
        let priorFailure = old?.request.isFailure == true ? old?.request : nil
        let agreesWithPriorFailure = observation.httpStatusCode == nil || priorFailure?.httpStatusCode == nil
            || observation.httpStatusCode == priorFailure?.httpStatusCode
        let value = UsageRequest(id: id, sessionID: session, deviceID: device, agent: source,
                                 timestamp: min(old?.request.timestamp ?? at, at),
                                 requestedModel: requestedModel, sentModel: observation.sent ?? old?.request.sentModel,
                                 provider: observation.provider ?? old?.request.provider,
                                 providerID: observation.providerID ?? old?.request.providerID,
                                 account: observation.account ?? old?.request.account, loginMethod: observation.login ?? old?.request.loginMethod,
                                 reasoningEffort: observation.effort ?? old?.request.reasoningEffort,
                                 serviceTier: tierConflict ? nil : observation.tier ?? old?.request.serviceTier,
                                 requestedServiceTier: observation.requestedTier ?? old?.request.requestedServiceTier,
                                 status: failed ? "failed" : "success",
                                 durationMS: duration,
                                 timingSource: observation.timing ?? old?.request.timingSource,
                                 estimatedDurationMS: estimated, estimatedTimingSource: estimated == nil ? nil : "claude-session-log",
                                 inputTokens: counts?.input ?? 0, outputTokens: counts?.output ?? 0, cacheReadTokens: counts?.read ?? 0,
                                 cacheWriteTokens: counts?.write ?? 0, reasoningTokens: counts?.reason,
                                 source: "claude.assistant", channel: observation.channel ?? old?.request.channel,
                                 cacheWrite5mTokens: observation.cache5m, cacheWrite1hTokens: observation.cache1h,
                                 actualServiceTierEvidence: tierConflict ? .conflicting : nil,
                                 httpStatusCode: observation.httpStatusCode ?? (failed ? priorFailure?.httpStatusCode : nil),
                                 message: failed ? observation.failureMessage ?? (agreesWithPriorFailure ? priorFailure?.message : nil) : nil)
        rows[id] = Revision(request: value, observedAt: at, counts: counts, previous: previous,
                            interval: interval)
        if interval.turn == observation.turn, !followedByInput,
           previousReply.map({ interval.end >= $0.interval.end }) ?? true {
            lastReply[observation.turn] = id
        }
    }
    let requests = rows.values.map(\.request)
    // Title events normally omit entrypoint; use the same agent classification
    // as that transcript's usage rather than copying the title across clients.
    let bySession = Dictionary(grouping: requests, by: \.sessionID)
    for (session, title) in nativeTitles {
        let agents = bySession[session].map { Set($0.map(\.agent)) } ?? [agent]
        for source in agents {
            let key = collectorSessionTitleKey(device: device, agent: source, session: session)
            putSessionTitle(title, for: key, in: &titles)
        }
    }
    return requests
}
