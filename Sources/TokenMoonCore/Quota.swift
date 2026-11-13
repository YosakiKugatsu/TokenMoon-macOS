// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Whether a reading may be used as fresh provider evidence.
public enum QuotaReadingProvenance: Equatable, Sendable {
    case live
    case cached
    case lastKnown
}

public enum QuotaReadingFreshness: Equatable, Sendable {
    case fresh
    case cached
    case stale
    case resetPending
    case unavailable
}

public struct QuotaWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let durationSeconds: Double?
    /// Only needed when a fallback combines readings observed at different times.
    public let observedAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date? = nil,
                durationSeconds: Double? = nil, observedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationSeconds = durationSeconds
        self.observedAt = observedAt
    }

    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    public var isValid: Bool { !id.isEmpty && usedPercent.isFinite && usedPercent >= 0 && usedPercent <= 100 }
}

public struct QuotaAccount: Identifiable, Equatable, Sendable {
    static let freshReadingAge: TimeInterval = 15 * 60

    public let id: String
    public let agent: Agent
    public let displayName: String
    public let plan: String?
    public let windows: [QuotaWindow]
    /// Time of an actual provider observation, if known. Reading a CLI cache
    /// does not establish when the provider measured the balance.
    public let observedAt: Date?
    public let provenance: QuotaReadingProvenance
    public let note: String?
    /// Verified by the currently authenticated native client. Used for local history matching only.
    public let accountEmail: String?

    public init(id: String, agent: Agent, displayName: String, plan: String? = nil,
                windows: [QuotaWindow], observedAt: Date? = nil, note: String? = nil, accountEmail: String? = nil,
                provenance: QuotaReadingProvenance = .live) {
        self.id = id
        self.agent = agent
        self.displayName = displayName
        self.plan = plan
        var seen: Set<String> = []
        self.windows = windows.filter { $0.isValid && seen.insert($0.id).inserted }
        self.observedAt = observedAt ?? (provenance == .live && !self.windows.isEmpty ? .now : nil)
        self.provenance = provenance
        self.note = note
        self.accountEmail = accountEmail
    }

    public var isCachedReading: Bool { provenance == .cached }

    public var liveObservationAt: Date? {
        provenance == .live && !windows.isEmpty ? observedAt : nil
    }

    public var lastKnown: Self { asLastKnown() }

    public func asLastKnown(note: String? = nil) -> Self {
        Self(id: id, agent: agent, displayName: displayName, plan: plan, windows: windows,
             observedAt: observedAt, note: note ?? self.note, accountEmail: accountEmail,
             provenance: isCachedReading ? .cached : .lastKnown)
    }

    public func observationTime(for window: QuotaWindow) -> Date? {
        window.observedAt ?? observedAt
    }

    /// Shared freshness semantics for the menu bar, popup, and dashboard.
    public func freshness(for window: QuotaWindow? = nil, now: Date = .now) -> QuotaReadingFreshness {
        let readingWindows = window.map { [$0] } ?? windows
        guard !readingWindows.isEmpty else { return .unavailable }
        if readingWindows.allSatisfy({ $0.resetsAt.map { $0 <= now } == true }) { return .resetPending }
        if isCachedReading { return .cached }
        guard let observedAt = window.map(observationTime(for:)) ?? observedAt, observedAt <= now else {
            return .unavailable
        }
        if provenance == .lastKnown || now.timeIntervalSince(observedAt) > Self.freshReadingAge { return .stale }
        return .fresh
    }

    public var planDisplayName: String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
        return switch plan.lowercased() {
        case "pro": "Pro"
        case "prolite", "pro lite": "Pro Lite"
        case "promax", "pro max": "Pro Max"
        case "pro 100": "Pro 100"
        case "pro 200": "Pro 200"
        case "pro 500": "Pro 500"
        case "plus": "Plus"
        case "free": "Free"
        case "go": "Go"
        case "max": "Max"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        default: plan
        }
    }

    /// Presentation of the two usual Codex meters, separate from observed data.
    public var codexMainAllowance: CodexMainAllowance? {
        guard agent == .codex, let plan = planDisplayName else { return nil }
        let isPro = ["Pro", "Pro Lite", "Pro Max", "Pro 100", "Pro 200", "Pro 500"].contains(plan)
        guard isPro || plan == "Plus" else { return nil }
        let standard = windows.filter { $0.id.hasPrefix("codex:") }
        let short = standard.first { $0.durationSeconds == 5 * 3600 }
        let weekly = standard.first { $0.durationSeconds == 7 * 86400 }
        guard short != nil || weekly != nil else { return nil }
        // OpenAI's Pro plans have only the main weekly allowance. An actual 5-hour
        // reading, or another standard window with an unfamiliar duration, takes
        // precedence over that documented policy.
        // A historical subset cannot tell us whether the live response still omits a short window.
        let noShortLimit = isPro && provenance != .lastKnown && weekly != nil && standard.count == 1
        return CodexMainAllowance(
            fiveHours: short.map(CodexMainAllowance.Reading.reported) ?? (noShortLimit ? .unlimited : .unavailable),
            sevenDays: weekly.map(CodexMainAllowance.Reading.reported) ?? .unavailable
        )
    }
}

public struct CodexMainAllowance: Equatable, Sendable {
    public enum Reading: Equatable, Sendable {
        case reported(QuotaWindow)
        case unlimited
        case unavailable
    }

    public let fiveHours: Reading
    public let sevenDays: Reading
}
