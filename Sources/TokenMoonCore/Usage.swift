// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum Agent: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claudeDesktop = "claude-desktop"
    case claudeCode = "claude-code"
    case antigravity
    case cpa

    public static let localCollectors: [Self] = [.codex, .claudeDesktop, .claudeCode, .antigravity]

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .codex: "Codex"
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .antigravity: "Antigravity"
        case .cpa: "CPA 网关"
        }
    }
}

/// User-facing execution family. The raw agent on each request remains the collector.
public enum UsageAgentGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, claude, gemini, antigravity, other

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .antigravity: "Antigravity"
        case .other: "其他"
        }
    }
}

public enum RequestStatusFacet: Hashable, Sendable, Identifiable, Comparable {
    case succeeded, failed, unknown, http(Int)

    public var id: String {
        switch self {
        case .succeeded: "success"
        case .failed: "failed"
        case .unknown: "unknown"
        case let .http(code): "http-\(code)"
        }
    }

    public init?(id: String) {
        switch id {
        case "success": self = .succeeded
        case "failed": self = .failed
        case "unknown": self = .unknown
        default:
            guard id.hasPrefix("http-"), let code = Int(id.dropFirst(5)), (100...599).contains(code) else { return nil }
            self = .http(code)
        }
    }

    public var label: String {
        switch self {
        case .succeeded: "成功"
        case .failed: "失败"
        case .unknown: "状态未记录"
        case let .http(code): "HTTP \(code)"
        }
    }

    private var order: Int {
        switch self {
        case .succeeded: 0
        case .failed: 1
        case .unknown: 2
        case let .http(code): code + 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }

    public func includes(_ request: UsageRequest) -> Bool {
        if case let .http(code) = self { return request.observedHTTPStatusCode == code }
        return request.statusFacet == self
    }
}

/// A positive observation about why the actual service tier is unknown.
/// Unlike an omitted tier, this must not revive a previously observed value.
public enum ActualServiceTierEvidence: String, Codable, Sendable {
    case conflicting
}

public enum LoginMethodEvidence: String, Codable, Sendable {
    /// Native authentication traces agreed for the entire turn.
    case turnTrace
    /// Traces disagreed or did not support an unambiguous attribution.
    case conflicting
}

func isExplicitAPIKeyLogin(_ raw: String?) -> Bool {
    guard let raw else { return false }
    let value = raw.lowercased()
    switch value {
    case "apikey", "api-key", "api_key": return true
    case "oauth", "chatgpt", "chatgpt_auth_tokens", "sso", "gateway-oidc": return false
    default: return value.filter { !$0.isWhitespace && $0 != "-" && $0 != "_" } == "apikey"
    }
}

public enum RequestAccountEvidence: String, Codable, Sendable {
    /// The user confirmed a historical request's account; the transcript did not record it.
    case userConfirmed = "user_confirmed"
}

public enum EstimatedTPSBasis: Equatable, Sendable {
    case log
    case cpaCompleteRequestFallback
}

/// Timing selected for the estimated view. This projection never fills raw
/// estimate fields or becomes evidence for the separate precise view.
public struct EstimatedTPSTiming: Equatable, Sendable {
    public let basis: EstimatedTPSBasis
    public let durationMS: Double
    public let source: String
}

public struct UsageRequest: Codable, Sendable, Equatable, Identifiable {
    // Views, collector snapshots, shard caches and sorted indices share request
    // payloads. Copy the payload only when merging or enriching a changed row.
    private struct Payload: Codable, Equatable, Sendable {
        var id: String
        var sessionID: String
        var deviceID: String
        var agent: Agent
        var timestamp: Date
        var requestedModel: String
        var sentModel: String?
        var provider: String?
        var providerID: String?
        var account: String?
        var accountEvidence: RequestAccountEvidence?
        var loginMethod: String?
        var loginMethodEvidence: LoginMethodEvidence?
        var sessionCreatorAccountID: String?
        var sessionCreatorAccountEmail: String?
        var reasoningEffort: String?
        var serviceTier: String?
        var actualServiceTierEvidence: ActualServiceTierEvidence?
        var requestedServiceTier: String?
        var sentServiceTier: String?
        var cpaKeyID: String?
        var cpaKeyLabel: String?
        var status: String
        var httpStatusCode: Int?
        var message: String?
        var durationMS: Double?
        var timingSource: String?
        var ttftMS: Double?
        var estimatedDurationMS: Double?
        var estimatedTimingSource: String?
        var inputTokens: Int64
        var outputTokens: Int64
        var cacheReadTokens: Int64
        var cacheWriteTokens: Int64
        var reasoningTokens: Int64?
        var source: String?
        var channel: String?
        var cacheWrite5mTokens: Int64?
        var cacheWrite1hTokens: Int64?
    }

    // A UsageRequest never mutates shared storage; callers keep value semantics.
    private final class Storage: @unchecked Sendable {
        var payload: Payload
        init(_ payload: Payload) { self.payload = payload }
    }

    private var storage: Storage

    private mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&storage) { storage = Storage(storage.payload) }
    }

    public init(from decoder: any Decoder) throws {
        var payload = try Payload(from: decoder)
        if let strings = decoder.userInfo[UsageStringInterner.key] as? UsageStringInterner {
            strings.canonicalize(&payload.sessionID)
            strings.canonicalize(&payload.deviceID)
            strings.canonicalize(&payload.requestedModel)
            strings.canonicalize(&payload.sentModel)
            strings.canonicalize(&payload.provider)
            strings.canonicalize(&payload.providerID)
            strings.canonicalize(&payload.account)
            strings.canonicalize(&payload.loginMethod)
            strings.canonicalize(&payload.sessionCreatorAccountID)
            strings.canonicalize(&payload.sessionCreatorAccountEmail)
            strings.canonicalize(&payload.reasoningEffort)
            strings.canonicalize(&payload.serviceTier)
            strings.canonicalize(&payload.requestedServiceTier)
            strings.canonicalize(&payload.sentServiceTier)
            strings.canonicalize(&payload.cpaKeyID)
            strings.canonicalize(&payload.cpaKeyLabel)
            strings.canonicalize(&payload.status)
            strings.canonicalize(&payload.timingSource)
            strings.canonicalize(&payload.estimatedTimingSource)
            strings.canonicalize(&payload.source)
            strings.canonicalize(&payload.channel)
        }
        storage = Storage(payload)
    }

    public func encode(to encoder: any Encoder) throws { try storage.payload.encode(to: encoder) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.payload == rhs.storage.payload
    }

    public var id: String {
        get { storage.payload.id }
        set { if storage.payload.id != newValue { makeUnique(); storage.payload.id = newValue } }
    }
    public var sessionID: String {
        get { storage.payload.sessionID }
        set { if storage.payload.sessionID != newValue { makeUnique(); storage.payload.sessionID = newValue } }
    }
    public var deviceID: String {
        get { storage.payload.deviceID }
        set { if storage.payload.deviceID != newValue { makeUnique(); storage.payload.deviceID = newValue } }
    }
    public var agent: Agent {
        get { storage.payload.agent }
        set { if storage.payload.agent != newValue { makeUnique(); storage.payload.agent = newValue } }
    }
    public var timestamp: Date {
        get { storage.payload.timestamp }
        set { if storage.payload.timestamp != newValue { makeUnique(); storage.payload.timestamp = newValue } }
    }
    public var requestedModel: String {
        get { storage.payload.requestedModel }
        set { if storage.payload.requestedModel != newValue { makeUnique(); storage.payload.requestedModel = newValue } }
    }
    public var sentModel: String? {
        get { storage.payload.sentModel }
        set { if storage.payload.sentModel != newValue { makeUnique(); storage.payload.sentModel = newValue } }
    }
    public var provider: String? {
        get { storage.payload.provider }
        set { if storage.payload.provider != newValue { makeUnique(); storage.payload.provider = newValue } }
    }
    public var providerID: String? {
        get { storage.payload.providerID }
        set { if storage.payload.providerID != newValue { makeUnique(); storage.payload.providerID = newValue } }
    }
    public var account: String? {
        get { storage.payload.account }
        set { if storage.payload.account != newValue { makeUnique(); storage.payload.account = newValue } }
    }
    public var accountEvidence: RequestAccountEvidence? {
        get { storage.payload.accountEvidence }
        set { if storage.payload.accountEvidence != newValue { makeUnique(); storage.payload.accountEvidence = newValue } }
    }
    public var loginMethod: String? {
        get { storage.payload.loginMethod }
        set { if storage.payload.loginMethod != newValue { makeUnique(); storage.payload.loginMethod = newValue } }
    }
    public var loginMethodEvidence: LoginMethodEvidence? {
        get { storage.payload.loginMethodEvidence }
        set { if storage.payload.loginMethodEvidence != newValue { makeUnique(); storage.payload.loginMethodEvidence = newValue } }
    }
    /// Account selected at session creation. It may differ from the account that served a resumed request.
    public var sessionCreatorAccountID: String? {
        get { storage.payload.sessionCreatorAccountID }
        set { if storage.payload.sessionCreatorAccountID != newValue { makeUnique(); storage.payload.sessionCreatorAccountID = newValue } }
    }
    /// Email verified against the native session's creator user and workspace.
    /// This is creator metadata, not evidence of the credential used by a resumed request.
    public var sessionCreatorAccountEmail: String? {
        get { storage.payload.sessionCreatorAccountEmail }
        set { if storage.payload.sessionCreatorAccountEmail != newValue { makeUnique(); storage.payload.sessionCreatorAccountEmail = newValue } }
    }
    public var reasoningEffort: String? {
        get { storage.payload.reasoningEffort }
        set { if storage.payload.reasoningEffort != newValue { makeUnique(); storage.payload.reasoningEffort = newValue } }
    }
    public var serviceTier: String? {
        get { storage.payload.serviceTier }
        set { if storage.payload.serviceTier != newValue { makeUnique(); storage.payload.serviceTier = newValue } }
    }
    public var actualServiceTierEvidence: ActualServiceTierEvidence? {
        get { storage.payload.actualServiceTierEvidence }
        set { if storage.payload.actualServiceTierEvidence != newValue { makeUnique(); storage.payload.actualServiceTierEvidence = newValue } }
    }
    public var requestedServiceTier: String? {
        get { storage.payload.requestedServiceTier }
        set { if storage.payload.requestedServiceTier != newValue { makeUnique(); storage.payload.requestedServiceTier = newValue } }
    }
    public var sentServiceTier: String? {
        get { storage.payload.sentServiceTier }
        set { if storage.payload.sentServiceTier != newValue { makeUnique(); storage.payload.sentServiceTier = newValue } }
    }
    public var cpaKeyID: String? {
        get { storage.payload.cpaKeyID }
        set { if storage.payload.cpaKeyID != newValue { makeUnique(); storage.payload.cpaKeyID = newValue } }
    }
    public var cpaKeyLabel: String? {
        get { storage.payload.cpaKeyLabel }
        set { if storage.payload.cpaKeyLabel != newValue { makeUnique(); storage.payload.cpaKeyLabel = newValue } }
    }
    public var status: String {
        get { storage.payload.status }
        set { if storage.payload.status != newValue { makeUnique(); storage.payload.status = newValue } }
    }
    public var httpStatusCode: Int? {
        get { storage.payload.httpStatusCode }
        set { if storage.payload.httpStatusCode != newValue { makeUnique(); storage.payload.httpStatusCode = newValue } }
    }
    /// Bounded, redacted diagnostic message. Never a request or response body.
    public var message: String? {
        get { storage.payload.message }
        set { if storage.payload.message != newValue { makeUnique(); storage.payload.message = newValue } }
    }
    public var durationMS: Double? {
        get { storage.payload.durationMS }
        set { if storage.payload.durationMS != newValue { makeUnique(); storage.payload.durationMS = newValue } }
    }
    public var timingSource: String? {
        get { storage.payload.timingSource }
        set { if storage.payload.timingSource != newValue { makeUnique(); storage.payload.timingSource = newValue } }
    }
    public var ttftMS: Double? {
        get { storage.payload.ttftMS }
        set { if storage.payload.ttftMS != newValue { makeUnique(); storage.payload.ttftMS = newValue } }
    }
    public var estimatedDurationMS: Double? {
        get { storage.payload.estimatedDurationMS }
        set { if storage.payload.estimatedDurationMS != newValue { makeUnique(); storage.payload.estimatedDurationMS = newValue } }
    }
    public var estimatedTimingSource: String? {
        get { storage.payload.estimatedTimingSource }
        set { if storage.payload.estimatedTimingSource != newValue { makeUnique(); storage.payload.estimatedTimingSource = newValue } }
    }
    public var inputTokens: Int64 {
        get { storage.payload.inputTokens }
        set { if storage.payload.inputTokens != newValue { makeUnique(); storage.payload.inputTokens = newValue } }
    }
    public var outputTokens: Int64 {
        get { storage.payload.outputTokens }
        set { if storage.payload.outputTokens != newValue { makeUnique(); storage.payload.outputTokens = newValue } }
    }
    public var cacheReadTokens: Int64 {
        get { storage.payload.cacheReadTokens }
        set { if storage.payload.cacheReadTokens != newValue { makeUnique(); storage.payload.cacheReadTokens = newValue } }
    }
    public var cacheWriteTokens: Int64 {
        get { storage.payload.cacheWriteTokens }
        set { if storage.payload.cacheWriteTokens != newValue { makeUnique(); storage.payload.cacheWriteTokens = newValue } }
    }
    public var reasoningTokens: Int64? {
        get { storage.payload.reasoningTokens }
        set { if storage.payload.reasoningTokens != newValue { makeUnique(); storage.payload.reasoningTokens = newValue } }
    }
    public var source: String? {
        get { storage.payload.source }
        set { if storage.payload.source != newValue { makeUnique(); storage.payload.source = newValue } }
    }
    public var channel: String? {
        get { storage.payload.channel }
        set { if storage.payload.channel != newValue { makeUnique(); storage.payload.channel = newValue } }
    }
    public var cacheWrite5mTokens: Int64? {
        get { storage.payload.cacheWrite5mTokens }
        set { if storage.payload.cacheWrite5mTokens != newValue { makeUnique(); storage.payload.cacheWrite5mTokens = newValue } }
    }
    public var cacheWrite1hTokens: Int64? {
        get { storage.payload.cacheWrite1hTokens }
        set { if storage.payload.cacheWrite1hTokens != newValue { makeUnique(); storage.payload.cacheWrite1hTokens = newValue } }
    }

    public init(
        id: String, sessionID: String, deviceID: String, agent: Agent, timestamp: Date,
        requestedModel: String, sentModel: String? = nil, provider: String? = nil, providerID: String? = nil,
        account: String? = nil, loginMethod: String? = nil, reasoningEffort: String? = nil,
        serviceTier: String? = nil, requestedServiceTier: String? = nil, status: String = "unknown",
        durationMS: Double? = nil, timingSource: String? = nil,
        estimatedDurationMS: Double? = nil, estimatedTimingSource: String? = nil,
        inputTokens: Int64 = 0, outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0, cacheWriteTokens: Int64 = 0, reasoningTokens: Int64? = nil,
        source: String? = nil, channel: String? = nil,
        cacheWrite5mTokens: Int64? = nil, cacheWrite1hTokens: Int64? = nil,
        actualServiceTierEvidence: ActualServiceTierEvidence? = nil,
        sessionCreatorAccountID: String? = nil, loginMethodEvidence: LoginMethodEvidence? = nil,
        sessionCreatorAccountEmail: String? = nil, sentServiceTier: String? = nil,
        cpaKeyID: String? = nil, cpaKeyLabel: String? = nil, ttftMS: Double? = nil,
        httpStatusCode: Int? = nil, message: String? = nil,
        accountEvidence: RequestAccountEvidence? = nil
    ) {
        self.storage = Storage(Payload(
            id: id, sessionID: sessionID, deviceID: deviceID, agent: agent, timestamp: timestamp,
            requestedModel: requestedModel, sentModel: sentModel, provider: provider, providerID: providerID,
            account: account, accountEvidence: accountEvidence, loginMethod: loginMethod,
            loginMethodEvidence: loginMethodEvidence, sessionCreatorAccountID: sessionCreatorAccountID,
            sessionCreatorAccountEmail: sessionCreatorAccountEmail, reasoningEffort: reasoningEffort,
            serviceTier: actualServiceTierEvidence == nil ? serviceTier : nil,
            actualServiceTierEvidence: actualServiceTierEvidence, requestedServiceTier: requestedServiceTier,
            sentServiceTier: sentServiceTier, cpaKeyID: cpaKeyID, cpaKeyLabel: cpaKeyLabel, status: status,
            httpStatusCode: httpStatusCode, message: message, durationMS: durationMS, timingSource: timingSource,
            ttftMS: ttftMS, estimatedDurationMS: estimatedDurationMS,
            estimatedTimingSource: estimatedTimingSource, inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens, source: source, channel: channel,
            cacheWrite5mTokens: cacheWrite5mTokens, cacheWrite1hTokens: cacheWrite1hTokens
        ))
    }

    public var key: UsageKey { .init(deviceID: deviceID.lowercased(), id: id) }
    public var sessionKey: String { [deviceID.lowercased(), agent.rawValue, sessionID].joined(separator: "/") }
    public var inputWithCache: Int64 { sumTokens(sumTokens(inputTokens, cacheReadTokens), cacheWriteTokens) }
    public var totalTokens: Int64 { sumTokens(inputWithCache, outputTokens) }
    public var cacheRate: Double? { inputWithCache > 0 ? Double(cacheReadTokens) / Double(inputWithCache) : nil }
    public var observedHTTPStatusCode: Int? {
        if let httpStatusCode, (100...599).contains(httpStatusCode) { return httpStatusCode }
        return Int(status.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { (100...599).contains($0) ? $0 : nil }
    }
    public var isFailure: Bool {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["failure", "failed", "error", "rejected", "cancelled", "canceled", "interrupted", "incomplete"].contains(value)
            || (observedHTTPStatusCode ?? 0) >= 400
    }
    public var statusFacet: RequestStatusFacet {
        if isFailure { return .failed }
        if let code = observedHTTPStatusCode { return code >= 200 ? .succeeded : .unknown }
        return ["success", "succeeded", "completed", "ok"].contains(status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ? .succeeded : .unknown
    }
    public var hasCompleteTiming: Bool {
        guard let durationMS, durationMS.isFinite, durationMS > 0, let timingSource else { return false }
        return !timingSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var tps: Double? {
        guard !isFailure, outputTokens > 0, hasCompleteTiming, let durationMS else { return nil }
        let value = Double(outputTokens) * 1_000 / durationMS
        return value.isFinite ? value : nil
    }
    public var estimatedTPS: Double? {
        estimatedTPSElapsedMS.map { Double(outputTokens) * 1_000 / $0 }
    }
    private static let estimatedDurationLimitMS = 7_200_000.0

    private var hasEstimatedTiming: Bool {
        guard let elapsed = estimatedDurationMS, elapsed.isFinite, elapsed > 0,
              elapsed < Self.estimatedDurationLimitMS, let estimatedTimingSource else { return false }
        return !estimatedTimingSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Prefer a valid log interval. Only a CPA gateway request may use proven
    /// complete timing when its log estimate is missing or unusable.
    public var estimatedTPSTiming: EstimatedTPSTiming? {
        guard !isFailure, outputTokens > 0 else { return nil }
        if hasEstimatedTiming, let elapsed = estimatedDurationMS, let source = estimatedTimingSource,
           Double(outputTokens) * 1_000 / elapsed <= 10_000 {
            return .init(basis: .log, durationMS: elapsed, source: source)
        }
        guard agent == .cpa, let timingSource, let durationMS, tps != nil else { return nil }
        let isGateway = source == "cpa-gateway" && timingSource == "cpa-request-latency"
        let isVerifiedPredecessor = source == "sub2api-usage-archive" && timingSource == "sub2api-usage-duration"
        guard isGateway || isVerifiedPredecessor else { return nil }
        return .init(basis: .cpaCompleteRequestFallback, durationMS: durationMS, source: timingSource)
    }

    public var estimatedTPSElapsedMS: Double? {
        estimatedTPSTiming?.durationMS
    }

    /// All aggregate scopes use the same timing validity and one-second minimum.
    fileprivate var aggregateEstimatedTPSTiming: EstimatedTPSTiming? {
        guard let timing = estimatedTPSTiming, timing.durationMS >= 1_000 else { return nil }
        return timing
    }
    public var modelIdentity: String {
        (sentModel?.isEmpty == false ? sentModel : nil) ?? requestedModel
    }
    /// A synthetic error response does not introduce a model into the usage facets.
    public var modelFacetIdentity: String? {
        guard isFailure else { return modelIdentity }
        let sentinels = ["", "unknown", "unknown-model", "<unknown>", "(unknown)", "未知模型", "synthetic", "<synthetic>"]
        return [sentModel, requestedModel].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !sentinels.contains($0.lowercased()) }
    }
    public var agentGroup: UsageAgentGroup {
        switch agent {
        case .codex: return .codex
        case .claudeCode, .claudeDesktop: return .claude
        case .antigravity: return .antigravity
        case .cpa: break
        }
        let provider = (providerID ?? provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case "openai", "codex", "chatgpt": return .codex
        case "anthropic", "claude", "claude.ai": return .claude
        case "google", "gemini", "vertex", "vertex-ai": return .gemini
        default: break
        }
        // Generic gateways may name the actual route only in the served model.
        let model = (sentModel ?? "").lowercased().split(separator: "/").last.map(String.init) ?? ""
        if model.hasPrefix("claude-") { return .claude }
        if model.hasPrefix("gemini-") { return .gemini }
        if ["gpt-", "codex", "chatgpt-"].contains(where: model.hasPrefix)
            || ["o1", "o3", "o4"].contains(where: { model == $0 || model.hasPrefix($0 + "-") }) {
            return .codex
        }
        if provider == "antigravity" { return .antigravity }
        switch channel?.lowercased() {
        case "gpt / codex", "codex": return .codex
        case "claude": return .claude
        case "gemini": return .gemini
        default: return .other
        }
    }
    public var channelIdentity: String {
        if let channel, !channel.isEmpty { return channel }
        let model = modelIdentity.lowercased()
        let provider = (providerID ?? provider ?? "").lowercased()
        if model.hasPrefix("claude-") || ["anthropic", "claude"].contains(provider) { return "Claude" }
        if ["gpt-", "codex", "chatgpt-"].contains(where: model.hasPrefix)
            || ["o1", "o3", "o4"].contains(where: { model == $0 || model.hasPrefix($0 + "-") })
            || ["openai", "codex"].contains(provider) { return "GPT / Codex" }
        if model.hasPrefix("gemini-") || ["google", "gemini"].contains(provider) { return "Gemini" }
        return "Other"
    }

    /// A rescanned transcript can omit timing/tier metadata previously observed for this same request.
    public func preservingEvidence(from previous: UsageRequest) -> UsageRequest {
        guard key == previous.key, agent == previous.agent, sessionID == previous.sessionID else { return self }
        var result = self
        let compatible = modelIdentity == previous.modelIdentity && isFailure == previous.isFailure
        let disagreeingTiers: Bool
        if compatible, !isFailure, agent == .claudeCode || agent == .claudeDesktop,
           let serviceTier, let earlier = previous.serviceTier, serviceTier != earlier {
            let comparableTier = ServiceTier(serviceTier), priorComparableTier = ServiceTier(earlier)
            disagreeingTiers = comparableTier != .unknown && priorComparableTier != .unknown && comparableTier != priorComparableTier
        } else {
            disagreeingTiers = false
        }
        if actualServiceTierEvidence == .conflicting || previous.actualServiceTierEvidence == .conflicting || disagreeingTiers {
            // A conflict belongs to the request identity, including when later copies have revised counters.
            result.actualServiceTierEvidence = .conflicting
            result.serviceTier = nil
        }
        if compatible, agent == previous.agent, sessionID == previous.sessionID {
            if httpStatusCode == nil { result.httpStatusCode = previous.observedHTTPStatusCode }
            if isFailure, observedHTTPStatusCode == nil || previous.observedHTTPStatusCode == nil
                || observedHTTPStatusCode == previous.observedHTTPStatusCode {
                result.message = message ?? previous.message
            }
            result.sessionCreatorAccountID = sessionCreatorAccountID ?? previous.sessionCreatorAccountID
            if result.sessionCreatorAccountEmail == nil, let creatorID = result.sessionCreatorAccountID,
               creatorID == previous.sessionCreatorAccountID {
                result.sessionCreatorAccountEmail = previous.sessionCreatorAccountEmail
            }
            let accountsAgree = account == nil || previous.account == nil || account == previous.account
            let methodsAgree = loginMethod == nil || previous.loginMethod == nil || loginMethod == previous.loginMethod
            if accountEvidence == .userConfirmed, previous.accountEvidence == nil, let observed = previous.account {
                result.account = observed
                result.accountEvidence = nil
            } else if accountsAgree, methodsAgree, account == nil {
                result.account = previous.account
                result.accountEvidence = previous.accountEvidence
            }
            let directlyObserved = loginMethod != nil && loginMethodEvidence == nil
            let priorDirect = previous.loginMethod != nil && previous.loginMethodEvidence == nil
            let conflictingTraces = loginMethodEvidence == .turnTrace && previous.loginMethodEvidence == .turnTrace
                && !methodsAgree
            if !directlyObserved, priorDirect, accountsAgree {
                result.loginMethod = previous.loginMethod
                result.loginMethodEvidence = nil
            } else if !directlyObserved,
                      loginMethodEvidence == .conflicting || previous.loginMethodEvidence == .conflicting || conflictingTraces {
                result.loginMethod = nil
                result.loginMethodEvidence = .conflicting
            } else if loginMethod == nil, accountsAgree {
                result.loginMethod = previous.loginMethod
                result.loginMethodEvidence = previous.loginMethodEvidence
            }
            if result.accountEvidence == .userConfirmed && !result.canCarryUserConfirmedAccount {
                result.account = nil
                result.accountEvidence = nil
            }
        }
        guard compatible, inputTokens == previous.inputTokens,
              outputTokens == previous.outputTokens, cacheReadTokens == previous.cacheReadTokens,
              cacheWriteTokens == previous.cacheWriteTokens else { return result }
        if !hasCompleteTiming, previous.hasCompleteTiming {
            result.durationMS = previous.durationMS
            result.timingSource = previous.timingSource
        }
        if !hasEstimatedTiming, previous.hasEstimatedTiming {
            result.estimatedDurationMS = previous.estimatedDurationMS
            result.estimatedTimingSource = previous.estimatedTimingSource
        }
        if result.actualServiceTierEvidence == nil {
            result.serviceTier = serviceTier ?? previous.serviceTier
        }
        result.requestedServiceTier = requestedServiceTier ?? previous.requestedServiceTier
        result.sentServiceTier = sentServiceTier ?? previous.sentServiceTier
        result.cpaKeyID = cpaKeyID ?? previous.cpaKeyID
        result.cpaKeyLabel = cpaKeyLabel ?? previous.cpaKeyLabel
        result.ttftMS = ttftMS ?? previous.ttftMS
        result.reasoningEffort = reasoningEffort ?? previous.reasoningEffort
        result.reasoningTokens = reasoningTokens ?? previous.reasoningTokens
        if cacheWrite5mTokens == nil, cacheWrite1hTokens == nil {
            result.cacheWrite5mTokens = previous.cacheWrite5mTokens
            result.cacheWrite1hTokens = previous.cacheWrite1hTokens
        }
        return result
    }

    public var isValid: Bool {
        guard !id.isEmpty, !sessionID.isEmpty, !deviceID.isEmpty, !requestedModel.isEmpty,
              timestamp.timeIntervalSince1970.isFinite,
              [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens].allSatisfy({ $0 >= 0 }),
              [reasoningTokens, cacheWrite5mTokens, cacheWrite1hTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { return false }
        if let reasoningTokens, reasoningTokens > outputTokens { return false }
        if actualServiceTierEvidence == .conflicting && serviceTier != nil { return false }
        if loginMethodEvidence == .conflicting && loginMethod != nil { return false }
        if loginMethodEvidence == .turnTrace && loginMethod == nil { return false }
        if accountEvidence == .userConfirmed && !canCarryUserConfirmedAccount { return false }
        if let email = sessionCreatorAccountEmail {
            guard agent == .codex, sessionCreatorAccountID.flatMap(UUID.init(uuidString:)) != nil,
                  creatorAccountEmail(email) == email else { return false }
        }
        if let durationMS, !durationMS.isFinite || durationMS <= 0 { return false }
        if let ttftMS, !ttftMS.isFinite || ttftMS <= 0 { return false }
        if let httpStatusCode, !(100...599).contains(httpStatusCode) { return false }
        if let message, message.utf8.count > 512 || message.rangeOfCharacter(from: .controlCharacters) != nil { return false }
        if estimatedDurationMS != nil || estimatedTimingSource != nil, !hasEstimatedTiming { return false }
        return true
    }

    private var canCarryUserConfirmedAccount: Bool {
        guard agent == .codex || agent == .claudeCode,
              let account, creatorAccountEmail(account) == account,
              loginMethodEvidence != .conflicting else { return false }
        return !isExplicitAPIKeyLogin(loginMethod)
    }
}

public struct UsageKey: Hashable, Sendable {
    public let deviceID: String
    public let id: String
}

func sumTokens(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : value
}

public enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case last24Hours, last7Days, last30Days, last90Days, all, custom
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .last24Hours: "近 24 小时"
        case .last7Days: "近 7 天"
        case .last30Days: "近 30 天"
        case .last90Days: "近 90 天"
        case .all: "全部时间"
        case .custom: "自定义"
        }
    }

    public func bounds(now: Date, customStart: Date, customEnd: Date, calendar: Calendar) -> Range<Date> {
        let today = calendar.startOfDay(for: now)
        func addDays(_ n: Int, _ date: Date) -> Date { calendar.date(byAdding: .day, value: n, to: date) ?? date }
        switch self {
        case .last24Hours: return now.addingTimeInterval(-24 * 3600)..<now
        case .last7Days: return addDays(-6, today)..<now
        case .last30Days: return addDays(-29, today)..<now
        case .last90Days: return addDays(-89, today)..<now
        case .all: return Date.distantPast..<Date.distantFuture
        case .custom:
            let earlier = min(customStart, customEnd), later = max(customStart, customEnd)
            let from = UsageBucketInterval.hour.interval(containing: earlier, calendar: calendar)
            let to = UsageBucketInterval.hour.interval(containing: later, calendar: calendar)
            return (from?.start ?? earlier)..<(to?.end ?? later)
        }
    }
}

/// Values available in a time window, independently of the active filters.
public struct UsageWindow: Sendable {
    public let requests: [UsageRequest]
    public let facets: Facets
    public var models: Set<String> { facets.models }
    public var devices: Set<String> { facets.devices }
    public var agents: Set<UsageAgentGroup> { facets.agents }
    public var tiers: Set<ServiceTier> { facets.tiers }
    public var statuses: Set<RequestStatusFacet> { facets.statuses }
    public var accounts: Set<UsageAccountFacet> { facets.accounts }

    public init(requests: [UsageRequest], bounds: Range<Date>) {
        self.requests = requests.filter { bounds.contains($0.timestamp) }
        self.facets = Facets(requests: self.requests[...])
    }

    /// The ledger is already sorted newest first. Preserve its order and the
    /// inclusive start / exclusive end of the original time filter.
    public static func indices(sortedNewestFirst requests: [UsageRequest], bounds: Range<Date>) -> Range<Int> {
        func boundary(from start: Int, where included: (Date) -> Bool) -> Int {
            var lower = start
            var upper = requests.endIndex
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if included(requests[middle].timestamp) { upper = middle }
                else { lower = middle + 1 }
            }
            return lower
        }
        let start = boundary(from: requests.startIndex) { $0 < bounds.upperBound }
        let end = boundary(from: start) { $0 < bounds.lowerBound }
        return start..<end
    }

    public struct Facets: Equatable, Sendable {
        public let models: Set<String>
        public let devices: Set<String>
        public let agents: Set<UsageAgentGroup>
        public let tiers: Set<ServiceTier>
        public let statuses: Set<RequestStatusFacet>
        public let accounts: Set<UsageAccountFacet>

        public init(requests: ArraySlice<UsageRequest>) {
            var models: Set<String> = [], devices: Set<String> = []
            var agents: Set<UsageAgentGroup> = [], tiers: Set<ServiceTier> = []
            var statuses: Set<RequestStatusFacet> = []
            var accounts: Set<UsageAccountFacet> = []
            var accountResolver = UsageAccountFacet.Resolver()
            for request in requests {
                if let identity = request.modelFacetIdentity { models.insert(identity) }
                devices.insert(request.deviceID.lowercased())
                agents.insert(request.agentGroup)
                tiers.insert(ServiceTier(request.requestedServiceTier))
                statuses.insert(request.statusFacet)
                accounts.insert(accountResolver.resolve(request))
                if let code = request.observedHTTPStatusCode { statuses.insert(.http(code)) }
            }
            self.models = models
            self.devices = devices
            self.agents = agents
            self.tiers = tiers
            self.statuses = statuses
            self.accounts = accounts
        }
    }
}

/// Output-token scope for the dashboard estimate. Both scopes keep the existing
/// timing validity and minimum duration; only the output-token threshold changes.
public enum EstimatedTPSOutputScope: String, CaseIterable, Hashable, Sendable {
    case all, over800
}

private struct EstimatedTPSAggregate: Equatable, Sendable {
    var samples = 0
    var fallbackSamples = 0
    var output: Double = 0
    var elapsedMS: Double = 0

    var rate: Double? { elapsedMS > 0 ? output * 1_000 / elapsedMS : nil }

    mutating func add(outputTokens: Int64, timing: EstimatedTPSTiming) {
        samples += 1
        if timing.basis == .cpaCompleteRequestFallback { fallbackSamples += 1 }
        output += Double(outputTokens)
        elapsedMS += timing.durationMS
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(samples: lhs.samples + rhs.samples,
              fallbackSamples: lhs.fallbackSamples + rhs.fallbackSamples,
              output: lhs.output + rhs.output, elapsedMS: lhs.elapsedMS + rhs.elapsedMS)
    }
}

public struct UsageMetrics: Equatable, Sendable {
    public var requests = 0
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheWriteTokens: Int64 = 0
    public var pricedRequests = 0
    public var cacheWriteFallbackRequests = 0
    public var unpricedRequests = 0
    public var excludedRequests = 0
    public var tpsSamples = 0
    private var tpsMean: Double = 0
    // Disjoint bands let each request contribute once while preserving the
    // existing >= 1,000-token aggregate for consumers outside the dashboard.
    private var estimatedLegacy = EstimatedTPSAggregate()
    private var estimated801To999 = EstimatedTPSAggregate()
    private var estimatedUpTo800 = EstimatedTPSAggregate()
    private var knownCostNanos: Decimal = 0

    public init() {}

    public var tokens: Int64 { sumTokens(inputWithCache, outputTokens) }
    private var inputWithCache: Int64 { sumTokens(sumTokens(inputTokens, cacheReadTokens), cacheWriteTokens) }
    public var cost: Double? {
        guard pricedRequests > 0 || (excludedRequests > 0 && unpricedRequests == 0) else { return nil }
        return NSDecimalNumber(decimal: knownCostNanos / 1_000_000_000).doubleValue
    }
    public var cacheRate: Double? { inputWithCache > 0 ? Double(cacheReadTokens) / Double(inputWithCache) : nil }
    public var tps: Double? { tpsSamples > 0 ? tpsMean : nil }
    public var estimatedTPS: Double? { estimatedLegacy.rate }
    public var estimatedTPSSamples: Int { estimatedLegacy.samples }
    public var estimatedTPSFallbackSamples: Int { estimatedLegacy.fallbackSamples }

    public func estimatedTPS(for scope: EstimatedTPSOutputScope) -> Double? {
        estimatedAggregate(for: scope).rate
    }
    public func estimatedTPSSamples(for scope: EstimatedTPSOutputScope) -> Int {
        estimatedAggregate(for: scope).samples
    }
    public func estimatedTPSFallbackSamples(for scope: EstimatedTPSOutputScope) -> Int {
        estimatedAggregate(for: scope).fallbackSamples
    }

    private func estimatedAggregate(for scope: EstimatedTPSOutputScope) -> EstimatedTPSAggregate {
        let over800 = estimatedLegacy + estimated801To999
        return scope == .over800 ? over800 : over800 + estimatedUpTo800
    }

    public mutating func add(_ record: UsageRequest, cost: RequestCost) {
        requests += 1
        inputTokens = sumTokens(inputTokens, record.inputTokens)
        outputTokens = sumTokens(outputTokens, record.outputTokens)
        cacheReadTokens = sumTokens(cacheReadTokens, record.cacheReadTokens)
        cacheWriteTokens = sumTokens(cacheWriteTokens, record.cacheWriteTokens)
        if let sample = record.tps {
            tpsSamples += 1
            tpsMean += (sample - tpsMean) / Double(tpsSamples)
        }
        if let timing = record.aggregateEstimatedTPSTiming {
            let tokens = record.outputTokens
            switch tokens {
            case 1_000...: estimatedLegacy.add(outputTokens: tokens, timing: timing)
            case 801...999: estimated801To999.add(outputTokens: tokens, timing: timing)
            default: estimatedUpTo800.add(outputTokens: tokens, timing: timing)
            }
        }
        switch cost {
        case let .priced(nanos): pricedRequests += 1; knownCostNanos += Decimal(nanos)
        case let .pricedWithCacheWriteFallback(nanos):
            pricedRequests += 1; cacheWriteFallbackRequests += 1; knownCostNanos += Decimal(nanos)
        case .unknown: unpricedRequests += 1
        case .excluded: excludedRequests += 1
        }
    }
}

public struct UsageBucket: Identifiable, Sendable {
    public let date: Date
    public let metrics: UsageMetrics
    public let endDate: Date?
    public var id: Date { date }
    public init(date: Date, metrics: UsageMetrics, endDate: Date? = nil) {
        self.date = date
        self.metrics = metrics
        self.endDate = endDate
    }
}

/// The identity used to partition the visible requests into chart series.
public enum UsageChartDimension: String, CaseIterable, Identifiable, Sendable {
    case model, device, account, agent, requestedTier, status

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .model: "模型"
        case .device: "设备"
        case .account: "账号"
        case .agent: "智能体"
        case .requestedTier: "请求档位"
        case .status: "状态"
        }
    }

    public func identity(for row: UsageRequest) -> String {
        switch self {
        case .model: row.modelFacetIdentity ?? ""
        case .device: row.deviceID.lowercased()
        case .account:
            accountIdentity(for: row)
        case .agent: row.agentGroup.rawValue
        case .requestedTier: ServiceTier(row.requestedServiceTier).rawValue
        case .status: (row.observedHTTPStatusCode.map(RequestStatusFacet.http) ?? row.statusFacet).id
        }
    }

    private func accountIdentity(for row: UsageRequest) -> String {
        var resolver = UsageAccountFacet.Resolver()
        return resolver.resolve(row).id
    }

    /// History is least-recent first. A dimension qualifies only when multiple
    /// choices were selected and at least two are actually present after the
    /// other filters and time bounds are applied.
    public static func automatic(
        recentDimensions: [Self], multiSelected: Set<Self>, visibleRows: [UsageRequest]
    ) -> Self {
        func qualifies(_ dimension: Self) -> Bool {
            guard multiSelected.contains(dimension) else { return false }
            var first: String?
            var accountResolver = UsageAccountFacet.Resolver()
            for row in visibleRows {
                let id = dimension == .account ? accountResolver.resolve(row).id : dimension.identity(for: row)
                guard !id.isEmpty else { continue }
                if let first, id != first { return true }
                first = id
            }
            return false
        }
        return recentDimensions.reversed().first(where: qualifies) ?? allCases.first(where: qualifies) ?? .model
    }
}

/// Usage for a single chart series in an occupied timeline bucket. The bounds
/// match the corresponding aggregate UsageBucket exactly.
public struct UsageSeriesBucket: Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let date: Date
        public let seriesIdentity: String
        public var modelIdentity: String { seriesIdentity }
    }

    public let date: Date
    public let endDate: Date?
    public let seriesIdentity: String
    public let metrics: UsageMetrics
    public var id: ID { .init(date: date, seriesIdentity: seriesIdentity) }
    public var modelIdentity: String { seriesIdentity }
}

public typealias UsageModelBucket = UsageSeriesBucket

public struct UsageSession: Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    /// Conversation-derived text is deliberately not collected.
    public var title: String? { nil }
    public let agent: Agent
    public let deviceID: String
    public let models: [String]
    public let startedAt: Date
    public let endedAt: Date
    public let metrics: UsageMetrics
}

public struct UsageSnapshot: Sendable {
    public let metrics: UsageMetrics
    public let timeline: [UsageBucket]
    /// Sparse, sorted by date and then series identity. Empty cells aren't
    /// materialized as zeroes, since rates and unknown costs have no value there.
    public let seriesTimeline: [UsageSeriesBucket]
    public let chartGrouping: UsageChartDimension
    public var modelTimeline: [UsageModelBucket] { chartGrouping == .model ? seriesTimeline : [] }
    public let timelineInterval: UsageBucketInterval
    public let sessions: [UsageSession]
    public let costs: [UsageKey: RequestCost]
    public let sessionRequests: [String: [UsageRequest]]

    public init(
        requests: [UsageRequest], range: UsageRange, bounds: Range<Date>, calendar: Calendar,
        prices: PricingEngine, allTimeSpan: ClosedRange<Date>? = nil,
        precomputedCosts: [UsageKey: RequestCost] = [:],
        targetBucketCount: Int = UsageBucketInterval.defaultTargetBucketCount,
        chartGrouping: UsageChartDimension = .model
    ) {
        var overall = UsageMetrics()
        var buckets: [Date: UsageMetrics] = [:]
        var seriesBuckets: [Date: [String: UsageMetrics]] = [:]
        var groups: [String: [UsageRequest]] = [:]
        var totals: [String: UsageMetrics] = [:]
        var costs = precomputedCosts
        var accountResolver = UsageAccountFacet.Resolver()
        let span: ClosedRange<Date>? = range == .all
            ? (allTimeSpan ?? Self.recordSpan(requests, in: bounds))
            : bounds.lowerBound...bounds.upperBound
        let interval = span.map {
            UsageBucketInterval.recommended(for: $0, calendar: calendar, targetBucketCount: targetBucketCount)
        } ?? .day
        let chartEnd = span.map {
            range == .all ? interval.interval(containing: $0.upperBound, calendar: calendar)?.end ?? $0.upperBound
                : $0.upperBound
        }
        let grid: [DateInterval]
        if let start = span?.lowerBound, let chartEnd, start < chartEnd {
            let raw = interval.buckets(in: start..<chartEnd, calendar: calendar)
            if range == .all {
                grid = raw
            } else {
                // Keep aligned interior buckets and expose the exact selected
                // bounds for the first/last ones, including chart drill-down.
                grid = raw.map { DateInterval(start: max(start, $0.start), end: min(chartEnd, $0.end)) }
            }
        } else {
            grid = []
        }
        for row in requests where bounds.contains(row.timestamp) {
            let key = row.key
            let cost: RequestCost
            if let known = costs[key] {
                cost = known
            } else {
                cost = prices.cost(row)
                costs[key] = cost
            }
            overall.add(row, cost: cost)
            let bin = Self.bucketStart(for: row.timestamp, grid: grid)
                ?? interval.interval(containing: row.timestamp, calendar: calendar)?.start
                ?? row.timestamp
            buckets[bin, default: UsageMetrics()].add(row, cost: cost)
            let identity = chartGrouping == .account ? accountResolver.resolve(row).id : chartGrouping.identity(for: row)
            if !identity.isEmpty {
                seriesBuckets[bin, default: [:]][identity, default: UsageMetrics()].add(row, cost: cost)
            }
            let sessionKey = row.sessionKey
            groups[sessionKey, default: []].append(row)
            totals[sessionKey, default: UsageMetrics()].add(row, cost: cost)
        }
        self.metrics = overall
        self.timelineInterval = interval
        let display = grid.map { bucket in
            UsageBucket(date: bucket.start, metrics: buckets.removeValue(forKey: bucket.start) ?? .init(),
                        endDate: min(bucket.end, chartEnd ?? bucket.end))
        }
        let timeline = (display + buckets.map { UsageBucket(date: $0.key, metrics: $0.value) })
            .sorted { $0.date < $1.date }
        self.timeline = timeline
        self.chartGrouping = chartGrouping
        self.seriesTimeline = timeline.flatMap { bucket -> [UsageSeriesBucket] in
            guard let bySeries = seriesBuckets[bucket.date] else { return [] }
            return bySeries.sorted { $0.key < $1.key }.map { identity, metrics in
                UsageSeriesBucket(date: bucket.date, endDate: bucket.endDate, seriesIdentity: identity, metrics: metrics)
            }
        }
        self.sessions = groups.compactMap { id, rows -> UsageSession? in
            guard let first = rows.first, let last = rows.last, let total = totals[id] else { return nil }
            return UsageSession(id: id, sessionID: first.sessionID,
                                agent: first.agent, deviceID: first.deviceID,
                                models: Array(Set(rows.compactMap(\.modelFacetIdentity))).sorted(),
                                startedAt: min(first.timestamp, last.timestamp),
                                endedAt: max(first.timestamp, last.timestamp), metrics: total)
        }.sorted { $0.endedAt == $1.endedAt ? $0.id < $1.id : $0.endedAt > $1.endedAt }
        self.sessionRequests = groups
        self.costs = costs
    }

    private static func recordSpan(_ requests: [UsageRequest], in bounds: Range<Date>) -> ClosedRange<Date>? {
        var start: Date?, end: Date?
        for request in requests where bounds.contains(request.timestamp) {
            start = min(start ?? request.timestamp, request.timestamp)
            end = max(end ?? request.timestamp, request.timestamp)
        }
        if let start, let end { return start...end }
        return nil
    }

    private static func bucketStart(for date: Date, grid: [DateInterval]) -> Date? {
        var lower = 0, upper = grid.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if grid[middle].start <= date { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0, date < grid[lower - 1].end else { return nil }
        return grid[lower - 1].start
    }
}
