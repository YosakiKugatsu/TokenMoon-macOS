// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A presentation catalog. Model IDs remain the keys used by usage, pricing, and sync.
public struct ModelNames: Sendable {
    private let names: [String: String]

    public static let empty = ModelNames(names: [:])
    public var count: Int { names.count }

    private init(names: [String: String]) { self.names = names }

    public static func bundled() throws -> ModelNames {
        guard let url = Bundle.main.url(forResource: "model-names", withExtension: "json")
            ?? Bundle.module.url(forResource: "model-names", withExtension: "json") else { throw CatalogError.invalid }
        return try decode(Data(contentsOf: url))
    }

    /// Accepts the provider catalog from models.dev and the app's compact offline snapshot.
    public static func decode(_ data: Data) throws -> ModelNames {
        guard data.count <= 20_000_000,
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.invalid
        }
        let result: [String: String]
        if let value = document["names"] {
            guard let entries = value as? [String: String], entries.count <= 30_000 else { throw CatalogError.invalid }
            result = entries.reduce(into: [:]) { result, pair in
                if let name = validatedName(pair.value), validID(pair.key) { result[pair.key] = name }
            }
        } else {
            result = fromProviderCatalog(document)
        }
        guard !result.isEmpty, result.count <= 30_000 else { throw CatalogError.invalid }
        return ModelNames(names: result)
    }

    public func merging(_ newer: ModelNames) -> ModelNames {
        ModelNames(names: names.merging(newer.names) { _, new in new })
    }

    public func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["names": names], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public func displayName(for rawID: String) -> String {
        switch rawID.lowercased() {
        case "", "unknown", "<synthetic>": return "未知模型"
        case "codex-auto-review": return "Codex Auto Review"
        default: return names[rawID] ?? Self.readableID(rawID)
        }
    }

    private static func fromProviderCatalog(_ document: [String: Any]) -> [String: String] {
        // Prefer the author's direct API entry for the families supported by TokenMoon.
        // Other providers may give the same short ID to different models. Only accept
        // a bare ID from them when they agree; their namespaced IDs stay distinct.
        let direct = ["openai", "anthropic", "google"]
        var authored: [String: String] = [:]
        var agreed: [String: String] = [:]
        var ambiguous: Set<String> = []
        var scoped: [String: String] = [:]
        for provider in direct + document.keys.filter({ !direct.contains($0) }).sorted() {
            guard validID(provider),
                  let entry = document[provider] as? [String: Any],
                  let models = entry["models"] as? [String: Any] else { continue }
            let isDirect = direct.contains(provider)
            for (id, rawModel) in models {
                guard validID(id), let model = rawModel as? [String: Any],
                      (model["id"] as? String).map({ $0 == id }) ?? true,
                      let name = validatedName(model["name"] as? String) else { continue }
                if let prior = agreed[id], prior != name { ambiguous.insert(id) }
                else { agreed[id] = name }
                let qualified = provider + "/" + id
                if validID(qualified) { scoped[qualified] = name }
                if isDirect {
                    authored[id] = authored[id] ?? name
                    if validID(qualified) { authored[qualified] = name }
                }
            }
        }
        let exact = agreed.filter { !ambiguous.contains($0.key) }
        return scoped.merging(exact) { _, name in name }.merging(authored) { _, name in name }
    }

    private static func validatedName(_ value: String?) -> String? {
        guard let value, safeText(value, limit: 128) else { return nil }
        let name = value.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func validID(_ value: String) -> Bool {
        safeText(value, limit: 512) && value == value.trimmingCharacters(in: .whitespaces)
    }

    private static func safeText(_ value: String, limit: Int) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= limit else { return false }
        return !value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    /// A readable rendering of the ID for local models and deployments absent from
    /// the catalog. Keep version, date and quantization as written when recognizable.
    private static func readableID(_ id: String) -> String {
        guard safeText(id, limit: 512) else { return "未知模型" }
        let leaf = String(id.split(separator: "/").last ?? Substring(id))
        let split = leaf.split(separator: ":", maxSplits: 1)
        let base = String(split.first ?? Substring(leaf))
        let variant = split.dropFirst().first
        let parts = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace }).map(String.init)
        guard let first = parts.first else { return leaf }
        let remaining = parts.dropFirst()
        let text: String
        if first.lowercased() == "gpt", let version = remaining.first, version.first?.isNumber == true {
            text = (["GPT-" + version] + remaining.dropFirst().map(title)).joined(separator: " ")
        } else if first.lowercased() == "claude",
                  let family = remaining.first(where: { ["opus", "sonnet", "haiku", "fable"].contains($0.lowercased()) }) {
            let components = remaining.filter { $0 != family }
            let version = components.prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
            let suffix = components.dropFirst(version.count).map { word in
                word.count == 8 && word.allSatisfy(\.isNumber) ? "(\(word))" : title(word)
            }
            text = (["Claude", title(family)] + (version.isEmpty ? [] : [version.joined(separator: ".")]) + suffix)
                .joined(separator: " ")
        } else {
            text = parts.map(title).joined(separator: " ")
        }
        return variant.map { text + " · " + $0 } ?? text
    }

    private static func title(_ word: String) -> String {
        let lower = word.lowercased()
        if let brand = ["gpt": "GPT", "chatgpt": "ChatGPT", "deepseek": "DeepSeek",
                        "glm": "GLM", "gguf": "GGUF", "minimax": "MiniMax"][lower] { return brand }
        if lower.first == "o", lower.dropFirst().first?.isNumber == true { return lower }
        // Uppercase only the first letter: product labels such as Qwen3.8, GSQ and RCO
        // keep their existing internal casing.
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    private enum CatalogError: LocalizedError {
        case invalid
        var errorDescription: String? { "模型名称目录格式无效或没有可用条目" }
    }
}
