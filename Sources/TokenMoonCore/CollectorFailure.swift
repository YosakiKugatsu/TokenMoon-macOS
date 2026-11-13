// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only call for allowlisted status fields in a request/error metadata record.
func collectorHTTPStatus(_ row: CollectorJSON?) -> Int? {
    guard let row else { return nil }
    for name in ["apiErrorStatus", "httpStatusCode", "http_status_code", "http.response.status_code",
                 "http.status_code", "statusCode", "status_code", "status"] {
        let status = row.number(name).flatMap(Int.init(exactly:)) ?? row.text(name).flatMap(Int.init)
        if let status, (100...599).contains(status) { return status }
    }
    return nil
}

/// Prefer explicit error metadata. Never retain a whole request/response,
/// synthetic assistant message, stack trace, authorization header or raw key.
func collectorFailureMessage(_ raw: Any?) -> String? {
    CollectorFailureText.clean(raw)
}

func collectorRecordedModel(_ raw: String?) -> String? {
    guard let value = raw, !["<synthetic>", "unknown", "(unknown)"].contains(value.lowercased()) else { return nil }
    return value
}

private enum CollectorFailureText {
    private static let sensitiveBody = regex(#"(?i)(?:-----BEGIN [^\r\n]*PRIVATE KEY-----|\b(?:request[_ ]body|response[_ ]body|messages|prompt|system_prompt|tool_input|headers)["']?\s*[:=])"#)
    private static let credentials = [
        regex(#"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=\-]{4,}"#),
        regex(#"(?i)\b(?:sk[-_]|sess-|gh[pousr]_|github_pat_|xox[a-z]-|rt_)[A-Za-z0-9_-]{8,}\b|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bAIza[A-Za-z0-9_-]{30,}\b|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#),
        regex(#"(?i)\b(?:authorization|proxy-authorization|(?:x[-_])?api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|id[-_ ]?token|client[-_ ]?secret|token|password|cookie|set-cookie)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;}]+)"#),
        regex(#"(?i)\b(?:https?|wss?)://[^\s<>\x22\x27]+"#),
    ]

    static func clean(_ raw: Any?) -> String? {
        let text: String?
        if let fields = raw as? CollectorJSON {
            text = explicitText(fields)
        } else {
            text = raw as? String
        }
        guard let text, text.utf8.count <= 8_192 else { return nil }
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let brace = line.firstIndex(of: "{") {
            // Some OTLP error strings carry the provider's JSON error wrapper.
            // Use only its explicit message/type, never a serialized body.
            if let bytes = String(line[brace...]).data(using: .utf8),
               let fields = (try? JSONSerialization.jsonObject(with: bytes)) as? CollectorJSON,
               let message = explicitText(fields) {
                line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            } else {
                line = String(line[..<brace])
            }
        }
        guard !line.isEmpty, line.rangeOfCharacter(from: .controlCharacters) == nil,
              sensitiveBody.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) == nil else { return nil }
        for pattern in credentials {
            line = pattern.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line),
                                                     withTemplate: "[已隐藏]")
        }
        var end = line.startIndex
        var bytes = 0
        while end < line.endIndex {
            let next = line.index(after: end)
            bytes += line[end..<next].utf8.count
            if bytes > 512 { break }
            end = next
        }
        return collectorText(String(line[..<end]), limit: 512)
    }

    private static func explicitText(_ fields: CollectorJSON) -> String? {
        let inner = fields.dict("error")
        return inner?["message"] as? String ?? fields["message"] as? String
            ?? inner?["type"] as? String ?? fields["type"] as? String
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
