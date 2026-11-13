// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Read OpenTelemetry Collector file-exporter JSON for Claude Code. An exact
/// (agent, session.id, request_id) joins the timeline row to the transcript.
/// No prompt/body records or individual API attempt durations are consumed.
func collectClaudeTelemetry(_ url: URL, device: String, agent: Agent) throws -> [UsageRequest] {
    let dates = CollectorDates()
    var requests: [String: UsageRequest] = [:]
    try readCollectorLines(url, markers: ["api_request", "api_error"]) { envelope in
        for resource in envelope["resourceLogs"] as? [CollectorJSON] ?? [] {
            let properties = telemetryAttributes(resource.dict("resource")?["attributes"])
            for scope in resource["scopeLogs"] as? [CollectorJSON] ?? [] {
                for log in scope["logRecords"] as? [CollectorJSON] ?? [] {
                    let attr = telemetryAttributes(log["attributes"])
                    let kind = attr.text("event.name") ?? log.text("eventName") ?? log.dict("body")?.text("stringValue")
                    guard ["api_request", "api_error", "claude_code.api_request", "claude_code.api_error"].contains(kind ?? ""),
                          let session = attr.text("session.id") ?? properties.text("session.id") else { continue }
                    let statusCode = collectorHTTPStatus(attr)
                    let failed = kind?.hasSuffix("api_error") == true || statusCode.map { $0 >= 400 } == true
                    let model = collectorRecordedModel(attr.text("gen_ai.request.model") ?? attr.text("model"))
                    guard failed || model != nil else { continue }
                    guard let identity = attr.text("request_id") ?? attr.text("gen_ai.response.id")
                            ?? (failed ? attr.text("client_request_id") : nil),
                          let timestamp = dates.parse(attr.text("event.timestamp")) ?? telemetryTimestamp(log) else { continue }
                    let entrypoint = attr.text("app.entrypoint") ?? attr.text("entrypoint")
                    let source: Agent = entrypoint == "claude-desktop" ? .claudeDesktop : agent
                    let id = collectorID(source.rawValue, session, "request", identity)
                    let duration = failed ? nil : attr.milliseconds("duration_ms")
                    // Take identity from this event. Resource attributes can
                    // be user-supplied, and user.id alone identifies an install.
                    let gateway = attr.text("identity.source") == "gateway-oidc"
                    let account = attr.text("user.email") ?? attr.text("user.account_email")
                        ?? attr.text("user.account_uuid") ?? attr.text("user.account_id")
                        ?? (gateway ? attr.text("user.id") : nil)
                    let login = attr.text("auth.type") ?? attr.text("auth_type") ?? (gateway ? "gateway-oidc" : nil)
                    let request = UsageRequest(id: id, sessionID: session, deviceID: device, agent: source, timestamp: timestamp,
                        requestedModel: model ?? "unknown",
                        sentModel: collectorRecordedModel(attr.text("gen_ai.response.model") ?? attr.text("response.model")),
                        provider: attr.text("provider"),
                        providerID: attr.text("provider.id"), account: account,
                        loginMethod: login, reasoningEffort: attr.text("effort"),
                        requestedServiceTier: collectorTier(attr.text("requested_service_tier")
                            ?? attr.text("requested_speed") ?? attr.text("speed")),
                        status: failed ? "failed" : "success",
                        durationMS: duration, timingSource: duration == nil ? nil : "claude-code-otel-api-request",
                        inputTokens: attr.number("input_tokens") ?? 0, outputTokens: attr.number("output_tokens") ?? 0,
                        cacheReadTokens: attr.number("cache_read_tokens") ?? 0, cacheWriteTokens: attr.number("cache_creation_tokens") ?? 0,
                        source: failed ? "claude.otel.api_error" : "claude.otel.api_request", httpStatusCode: statusCode,
                        message: failed ? collectorFailureMessage(attr["error.message"]) ?? collectorFailureMessage(attr["error"]) : nil)
                    if let old = requests[id], failed {
                        if !old.isFailure { continue }
                        requests[id] = enrichClaudeFailure(old, using: request)
                    } else {
                        requests[id] = request
                    }
                }
            }
        }
    }
    return Array(requests.values)
}

private func telemetryAttributes(_ raw: Any?) -> CollectorJSON {
    var out: CollectorJSON = [:]
    for entry in raw as? [CollectorJSON] ?? [] {
        guard let key = entry.text("key"), let value = entry.dict("value") else { continue }
        if let integer = value.text("intValue"), let number = Int64(integer) {
            out[key] = NSNumber(value: number)
        } else if let int = value["intValue"] as? NSNumber {
            out[key] = int
        } else if ["error", "error.message"].contains(key), let raw = value["stringValue"] as? String {
            // Error text is bounded and sanitized later. Do not use generic
            // log body/content fields as error messages.
            if raw.utf8.count <= 8_192 { out[key] = raw }
        } else if let text = value.text("stringValue") {
            // Claude Code versions before 2.1.122 exported numbers as strings.
            if ["duration_ms", "input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens"].contains(key),
               let number = Double(text), number.isFinite {
                out[key] = NSNumber(value: number)
            } else {
                out[key] = text
            }
        } else if let double = value["doubleValue"] as? NSNumber {
            out[key] = double
        }
    }
    return out
}

private func telemetryTimestamp(_ log: CollectorJSON) -> Date? {
    guard let text = log.text("timeUnixNano"), let ns = UInt64(text), ns > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(ns) / 1_000_000_000)
}

func enrichClaudeTranscript(_ row: UsageRequest, using telemetry: UsageRequest) -> UsageRequest {
    var result = row
    if let duration = telemetry.durationMS {
        result.durationMS = duration
        result.timingSource = telemetry.timingSource
        result.estimatedDurationMS = nil
        result.estimatedTimingSource = nil
    }
    result.account = row.account ?? telemetry.account
    result.provider = row.provider ?? telemetry.provider
    result.providerID = row.providerID ?? telemetry.providerID
    result.loginMethod = row.loginMethod ?? telemetry.loginMethod
    result.requestedServiceTier = row.requestedServiceTier ?? telemetry.requestedServiceTier
    result.reasoningEffort = row.reasoningEffort ?? telemetry.reasoningEffort
    result.httpStatusCode = row.httpStatusCode ?? telemetry.httpStatusCode
    return result
}

func enrichClaudeFailure(_ row: UsageRequest, using telemetry: UsageRequest) -> UsageRequest {
    guard row.key == telemetry.key, row.agent == telemetry.agent, row.sessionID == telemetry.sessionID,
          row.isFailure, telemetry.isFailure else { return row }
    var result = row
    if collectorRecordedModel(row.requestedModel) == nil,
       let model = collectorRecordedModel(telemetry.requestedModel) {
        result.requestedModel = model
    }
    result.sentModel = row.sentModel ?? telemetry.sentModel
    result.httpStatusCode = row.httpStatusCode ?? telemetry.httpStatusCode
    let sameFailure = row.httpStatusCode == nil || telemetry.httpStatusCode == nil || row.httpStatusCode == telemetry.httpStatusCode
    if sameFailure, let error = telemetry.message,
       row.message == nil || row.message?.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil {
        result.message = error
    }
    result.provider = row.provider ?? telemetry.provider
    result.providerID = row.providerID ?? telemetry.providerID
    result.account = row.account ?? telemetry.account
    result.loginMethod = row.loginMethod ?? telemetry.loginMethod
    result.requestedServiceTier = row.requestedServiceTier ?? telemetry.requestedServiceTier
    result.reasoningEffort = row.reasoningEffort ?? telemetry.reasoningEffort
    return result
}
