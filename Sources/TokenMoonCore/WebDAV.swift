// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct WebDAVConfiguration: Sendable {
    public let url: URL
    public let username: String
    public let password: String

    public init(url: URL, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }
}

public struct WebDAVSyncResult: Sendable {
    /// The union read from the shared directory, including any history for this device.
    public var remoteRequests: [UsageRequest] {
        if supersededOwnedRequests.isEmpty { return cachedShards.requests }
        return cachedShards.requests.filter { $0.deviceID != ownerDeviceID || !supersededOwnedRequests.contains($0.id) }
    }
    public let deviceNames: [String: String]
    /// Save locally with the connection's remote ledger and pass back on the next sync.
    public let cachedShards: WebDAVShardCache
    /// A valid directory listing can yield a partial sync. Other shards still advance.
    public let issues: [WebDAVShardIssue]
    public var quotaObservations: [QuotaWireObservation] { cachedShards.quotaObservations }
    fileprivate let ownerDeviceID: String
    fileprivate let supersededOwnedRequests: Set<String>
}

public struct WebDAVShardIssue: Equatable, Sendable {
    public enum Operation: String, Sendable { case read, publish }

    public let filename: String
    public let operation: Operation
    public let message: String
    public let retainedCachedData: Bool
}

/// Typed, usage-only copies of validated shards. Never includes passwords or
/// verbatim response JSON. Entries are scoped to their original DAV directory and user.
public struct WebDAVShardCache: Codable, Sendable {
    fileprivate let directory: URL
    fileprivate let username: String
    fileprivate let shards: [ShardName: RemoteShard]

    public var requests: [UsageRequest] {
        // Later months win for an externally duplicated ID.
        var rows: [UsageKey: UsageRequest] = [:]
        for (_, remote) in shards.sorted(by: { $0.key < $1.key }) {
            for row in remote.shard.requests { rows[row.key] = row }
        }
        return rows.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return ($0.deviceID, $0.id) < ($1.deviceID, $1.id)
        }
    }

    public var quotaObservations: [QuotaWireObservation] {
        shards.sorted(by: { $0.key < $1.key }).flatMap { $0.value.shard.quotaObservations ?? [] }
    }

    /// The dashboard already merges and sorts all sources once. Pass it the
    /// existing monthly arrays instead of building a second flattened ledger.
    public var requestBatches: [[UsageRequest]] {
        shards.sorted(by: { $0.key < $1.key }).map { $0.value.shard.requests }
    }

    /// Only strong ETags prove that both caches refer to the same bytes.
    public func hasSameVersions(as other: Self) -> Bool {
        guard directory == other.directory, username == other.username, shards.count == other.shards.count else { return false }
        return shards.allSatisfy { name, entry in
            guard let prior = other.shards[name], let tag = WebDAVClient.strongETag(entry.etag) else { return false }
            return tag == WebDAVClient.strongETag(prior.etag) && entry.needsRedaction == prior.needsRedaction
        }
    }

    fileprivate init(directory: URL, username: String, shards: [ShardName: RemoteShard]) {
        self.directory = directory
        self.username = username
        self.shards = shards
    }

    private enum CodingKeys: String, CodingKey { case version, directory, username, shards }

    private struct FilenameKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported WebDAV cache version")
        }
        directory = try container.decode(URL.self, forKey: .directory)
        username = try container.decode(String.self, forKey: .username)
        let stored = try container.nestedContainer(keyedBy: FilenameKey.self, forKey: .shards)
        var valid: [ShardName: RemoteShard] = [:]
        for key in stored.allKeys {
            guard let name = ShardName(filename: key.stringValue),
                  let entry = try? stored.decode(RemoteShard.self, forKey: key),
                  WebDAVClient.isValid(entry.shard, for: name) else { continue }
            valid[name] = entry
        }
        shards = valid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(directory, forKey: .directory)
        try container.encode(username, forKey: .username)
        try container.encode(Dictionary(uniqueKeysWithValues: shards.map { ($0.key.filename, $0.value) }), forKey: .shards)
    }

    /// Write the existing cache representation incrementally, using the same
    /// UTC millisecond encoding as the desktop's ledger. The caller owns the file.
    public func writeJSON(to handle: FileHandle) throws {
        var writer = WireJSONWriter(handle: handle)
        try writer.write("{\"directory\":")
        try writer.encode(directory)
        try writer.write(",\"shards\":{")
        for (index, entry) in shards.sorted(by: { $0.key < $1.key }).enumerated() {
            try Task.checkCancellation()
            if index != 0 { try writer.write(",") }
            try writer.encode(entry.key.filename)
            try writer.write(":{")
            if let etag = entry.value.etag {
                try writer.write("\"etag\":")
                try writer.encode(etag)
                try writer.write(",")
            }
            try writer.write("\"needsRedaction\":")
            try writer.encode(entry.value.needsRedaction)
            try writer.write(",\"shard\":")
            try writer.encodeShard(entry.value.shard)
            try writer.write("}")
        }
        try writer.write("},\"username\":")
        try writer.encode(username)
        try writer.write(",\"version\":1}")
        try writer.flush()
    }

    /// Read the cache's existing JSON format with at most one request's JSON
    /// syntax tree in memory. Invalid individual entries are ignored, as in
    /// the Codable initializer; the surrounding cache header must be valid.
    public static func readJSON(_ data: Data, range: Range<Int>, decoder: JSONDecoder) throws -> Self {
        let header = try WireJSONMembers(data, range: range, decoder: decoder)
        guard try header.value(Int.self, "version") == 1 else { throw header.malformed }
        let directory = try header.value(URL.self, "directory")
        let username = try header.value(String.self, "username")
        let entries = try JSONMemberSlices.members(in: data, range: header.requiredRange("shards"))
        var valid: [ShardName: RemoteShard] = [:]
        valid.reserveCapacity(entries.count)
        for (filename, range) in entries {
            try Task.checkCancellation()
            guard let name = ShardName(filename: filename) else { continue }
            do {
                let remote = try WireJSONMembers(data, range: range, decoder: decoder)
                let decoded = try WireShardReader.read(data, range: remote.requiredRange("shard"),
                                                       name: name, inspectLegacyKeys: false, decoder: decoder)
                let etag = try remote.optional(String.self, "etag")
                let redaction = try remote.value(Bool.self, "needsRedaction")
                valid[name] = RemoteShard(shard: decoded.shard, etag: etag, needsRedaction: redaction)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return Self(directory: directory, username: username, shards: valid)
    }
}

public enum WebDAVError: LocalizedError, Sendable {
    case invalidEndpoint
    case invalidCredentials
    case invalidDevice
    case unexpectedResponse
    case http(String, Int)
    case invalidListing
    case invalidShard(String)
    case unsupportedSchema(String, Int)
    case oversized(String)
    case missingStrongETag(String)
    case contention(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "WebDAV 地址须指向现有的 HTTPS 目录，且不能包含账号、密码、查询参数或片段。"
        case .invalidCredentials:
            "WebDAV 用户名不能含冒号；若填写密码，也须填写用户名。"
        case .invalidDevice:
            "本机设备标识无效，或待同步的请求不属于本机。"
        case .unexpectedResponse:
            "服务器未返回有效的 HTTP 响应。"
        case let .http(method, status):
            "WebDAV \(method) 返回 HTTP \(status)。"
        case .invalidListing:
            "服务器未返回有效的 WebDAV 目录清单。"
        case let .invalidShard(name):
            "同步文件 \(name) 与 TokenMoon v1 格式不符。"
        case let .unsupportedSchema(name, version):
            "同步文件 \(name) 使用尚未支持的版本 \(version)。"
        case let .oversized(name):
            "\(name) 超过 48 MiB 的同步文件上限。"
        case let .missingStrongETag(name):
            "WebDAV 没有为 \(name) 返回强 ETag，已跳过改写以保护远端记录。"
        case let .contention(name):
            "同步文件 \(name) 正在被其他客户端更新，请稍后重试。"
        }
    }
}

public struct WebDAVClient: Sendable {
    public static let directoryName = "tokenmoon-v1"
    // Historical gateway months can exceed 32 MiB after a verified backfill.
    private static let maxBytes = 48 * 1_024 * 1_024

    private let configuration: WebDAVConfiguration
    private let session: DAVSession

    public init(configuration: WebDAVConfiguration) {
        self.configuration = configuration
        session = DAVSession()
    }

    /// On upgrade, preserve previously validated reads when a new read fails.
    /// Flat legacy ledgers contain no validators, so these never skip a GET.
    public func legacyShardCache(
        requests: [UsageRequest], deviceNames: [String: String], capturedAt: Date
    ) -> WebDAVShardCache? {
        guard let directory = try? Self.directory(for: configuration.url), !requests.isEmpty else { return nil }
        var grouped: [ShardName: [String: UsageRequest]] = [:]
        for request in requests where Self.isValid(request) {
            let name = ShardName(deviceID: request.deviceID, month: Self.month(for: request.timestamp))
            guard ShardName(filename: name.filename) == name else { continue }
            grouped[name, default: [:]][request.id] = request
        }
        var shards: [ShardName: RemoteShard] = [:]
        for (name, rows) in grouped {
            let deviceName = deviceNames[name.deviceID]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let shard = Shard(schemaVersion: 1, deviceID: name.deviceID,
                              deviceName: deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? name.deviceID,
                              month: name.month, updatedAt: capturedAt, requests: Array(rows.values))
            if Self.isValid(shard, for: name) {
                shards[name] = .init(shard: shard, etag: nil, needsRedaction: false)
            }
        }
        return shards.isEmpty ? nil : .init(directory: directory, username: configuration.username, shards: shards)
    }

    /// Pass only this device's rows and exact superseded IDs. Peers' shards are read-only.
    public func sync(
        deviceID: String, deviceName: String, requests: [UsageRequest],
        cachedShards: WebDAVShardCache? = nil, supersededRequestIDs: Set<String> = [],
        quotaObservations: [QuotaWireObservation] = []
    ) async throws -> WebDAVSyncResult {
        guard let deviceUUID = UUID(uuidString: deviceID), deviceID == deviceUUID.uuidString.lowercased(),
              !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              requests.allSatisfy({ $0.deviceID == deviceID && Self.isValid($0) }),
              quotaObservations.allSatisfy(\.isValid) else {
            throw WebDAVError.invalidDevice
        }

        let directory = try Self.directory(for: configuration.url)
        let username = configuration.username
        guard !username.contains(":"), !username.isEmpty || configuration.password.isEmpty else {
            throw WebDAVError.invalidCredentials
        }

        let listed = try await discover(in: directory)
        let prior = cachedShards.flatMap {
            $0.directory == directory && $0.username == username ? $0.shards : nil
        } ?? [:]
        let own = Dictionary(grouping: requests.lazy.filter { !supersededRequestIDs.contains($0.id) },
                             by: { ShardName(deviceID: deviceID, month: Self.month(for: $0.timestamp)) })
        let ownQuota = Dictionary(grouping: quotaObservations,
                                  by: { ShardName(deviceID: deviceID, month: Self.month(for: $0.observedAt)) })
        var read: [ShardName: RemoteShard] = [:]
        var unreadable: Set<ShardName> = []
        var issues: [WebDAVShardIssue] = []
        // A history month can be tens of MiB on the wire. Limit concurrent
        // decodes so restoring several months cannot swamp the desktop.
        let readConcurrency = 3
        for start in stride(from: 0, to: listed.count, by: readConcurrency) {
            try Task.checkCancellation()
            let batch = listed[start ..< min(start + readConcurrency, listed.count)]
            let responses = try await withThrowingTaskGroup(of: (ShardName, ReadOutcome).self) { group in
                for entry in batch {
                    let name = entry.name
                    group.addTask {
                        let cached = prior[name]
                        if name.deviceID != deviceID, let cached, let etag = entry.etag, Self.strongETag(cached.etag) == etag {
                            // For a read-only peer, the successful DAV:getetag
                            // property can avoid the GET entirely. Owners still
                            // need a successful GET/304 before they can write.
                            return (name, .read(cached))
                        }
                        do {
                            return (name, .read(try await get(name, in: directory, cached: cached,
                                                             inspectLegacyKeys: name.deviceID == deviceID)))
                        } catch {
                            try Task.checkCancellation()
                            return (name, .failed(cached, error.localizedDescription))
                        }
                    }
                }
                return try await group.reduce(into: [(ShardName, ReadOutcome)]()) { $0.append($1) }
            }
            for (name, outcome) in responses {
                switch outcome {
                case let .read(shard):
                    read[name] = shard
                case let .failed(cached, message):
                    unreadable.insert(name)
                    read[name] = cached
                    issues.append(.init(filename: name.filename, operation: .read, message: message,
                                        retainedCachedData: cached != nil))
                }
            }
        }

        // Rewrite owned legacy shards and remove proven aliases, even for months
        // no longer in the local ledger. Cached fallback data cannot authorize writes.
        let toPublish = Set(own.keys).union(ownQuota.keys).union(read.compactMap { name, remote in
            guard name.deviceID == deviceID else { return nil }
            let superseded = !supersededRequestIDs.isEmpty
                && remote.shard.requests.contains { supersededRequestIDs.contains($0.id) }
            return remote.shard.deviceName != deviceName || remote.needsRedaction || superseded ? name : nil
        })
        for name in toPublish.sorted() where !unreadable.contains(name) {
            try Task.checkCancellation()
            do {
                guard ShardName(filename: name.filename) == name else { throw WebDAVError.invalidDevice }
                read[name] = try await publish(
                    name, deviceName: deviceName, local: own[name] ?? [], existing: read[name],
                    localQuota: ownQuota[name] ?? [], supersededRequestIDs: supersededRequestIDs, in: directory
                )
            } catch {
                try Task.checkCancellation()
                issues.append(.init(filename: name.filename, operation: .publish, message: error.localizedDescription,
                                    retainedCachedData: read[name] != nil))
            }
        }

        try Task.checkCancellation()
        var deviceNames: [String: String] = [deviceID: deviceName]
        var latestName: [String: Date] = [:]
        for (key, value) in read.sorted(by: { $0.key < $1.key }) {
            let shard = value.shard
            if key.deviceID != deviceID, latestName[key.deviceID].map({ $0 <= shard.updatedAt }) ?? true {
                latestName[key.deviceID] = shard.updatedAt
                deviceNames[key.deviceID] = shard.deviceName
            }
        }
        let cache = WebDAVShardCache(directory: directory, username: username, shards: read)
        return WebDAVSyncResult(deviceNames: deviceNames,
                                cachedShards: cache,
                                issues: issues.sorted { ($0.filename, $0.operation.rawValue) < ($1.filename, $1.operation.rawValue) },
                                ownerDeviceID: deviceID, supersededOwnedRequests: supersededRequestIDs)
    }

    private static func directory(for url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              !host.isEmpty,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw WebDAVError.invalidEndpoint
        }
        return url.appendingPathComponent(directoryName, isDirectory: true)
    }

    private func makeRequest(_ method: String, to url: URL, body: Data? = nil,
                             headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        if !configuration.username.isEmpty {
            let credentials = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func download(_ method: String, from url: URL, body: Data? = nil,
                          headers: [String: String] = [:]) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        let request = makeRequest(method, to: url, body: body, headers: headers)
        let (file, response) = try await session.value.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: file)
            throw WebDAVError.unexpectedResponse
        }
        return (file, http)
    }

    private func upload(_ file: URL, to url: URL, headers: [String: String]) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        // Keep the fixed-size PUT transport used by existing DAV proxies.
        // Mapping the already encoded shard avoids a full JSONEncoder buffer.
        let body = try Data(contentsOf: file, options: .mappedIfSafe)
        let request = makeRequest("PUT", to: url, body: body, headers: headers)
        let (_, response) = try await session.value.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.unexpectedResponse }
        return http
    }

    private static func checkSize(_ file: URL, name: String) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= Self.maxBytes else { throw WebDAVError.oversized(name) }
    }

    private func discover(in directory: URL) async throws -> [ListedShard] {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/><D:getetag/></D:prop></D:propfind>
        """.utf8)
        let headers = ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"]
        var (file, response) = try await download("PROPFIND", from: directory, body: body, headers: headers)
        defer { try? FileManager.default.removeItem(at: file) }
        if response.statusCode == 404 {
            let (receipt, creation) = try await download("MKCOL", from: directory)
            try? FileManager.default.removeItem(at: receipt)
            // Another device may create the collection between PROPFIND and MKCOL.
            guard [201, 405].contains(creation.statusCode) else { throw WebDAVError.http("MKCOL", creation.statusCode) }
            try? FileManager.default.removeItem(at: file)
            (file, response) = try await download("PROPFIND", from: directory, body: body, headers: headers)
        }
        guard response.statusCode == 207 else { throw WebDAVError.http("PROPFIND", response.statusCode) }
        try Self.checkSize(file, name: "WebDAV 目录清单")

        let reader = DirectoryListing()
        guard let parser = XMLParser(contentsOf: file) else { throw WebDAVError.invalidListing }
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.isDAV else { throw WebDAVError.invalidListing }
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        var entries: [ShardName: ListedShard] = [:]
        for item in reader.responses {
            guard let url = URL(string: item.href, relativeTo: directory)?.absoluteURL,
                  url.scheme?.lowercased() == directory.scheme?.lowercased(),
                  url.host?.lowercased() == directory.host?.lowercased(),
                  Self.port(of: url) == Self.port(of: directory),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.hasPrefix(prefix),
                  let name = ShardName(filename: String(url.path.dropFirst(prefix.count))) else { continue }
            let etag = Self.strongETag(item.etag)
            let unambiguous = entries[name].map { $0.etag == etag } ?? true
            entries[name] = ListedShard(name: name, etag: unambiguous ? etag : nil)
        }
        return entries.values.sorted { $0.name < $1.name }
    }

    private static func port(of url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private func get(_ name: ShardName, in directory: URL, cached: RemoteShard? = nil,
                     inspectLegacyKeys: Bool = true) async throws -> RemoteShard? {
        let validator = Self.strongETag(cached?.etag)
        let headers = validator.map { ["If-None-Match": $0] } ?? [:]
        let (file, response) = try await download("GET", from: directory.appendingPathComponent(name.filename), headers: headers)
        defer { try? FileManager.default.removeItem(at: file) }
        if response.statusCode == 304, let validator, let cached {
            if let returned = response.value(forHTTPHeaderField: "ETag"), Self.strongETag(returned) != validator {
                // Weak comparison can produce 304 even if the strong validator
                // changed. A fresh read is needed before any later conditional PUT.
                return try await get(name, in: directory, inspectLegacyKeys: inspectLegacyKeys)
            }
            return cached
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw WebDAVError.http("GET", response.statusCode) }
        try Self.checkSize(file, name: name.filename)
        let decoded = try await session.decoder.decode(file: file, name: name, inspectLegacyKeys: inspectLegacyKeys)
        return RemoteShard(shard: decoded.shard, etag: response.value(forHTTPHeaderField: "ETag"),
                           needsRedaction: decoded.needsRedaction)
    }

    private func publish(
        _ name: ShardName, deviceName: String, local: [UsageRequest], existing: RemoteShard?,
        localQuota: [QuotaWireObservation], supersededRequestIDs: Set<String>, in directory: URL
    ) async throws -> RemoteShard? {
        let url = directory.appendingPathComponent(name.filename)
        var previous = existing
        for attempt in 0 ..< 4 {
            if attempt > 0 { previous = try await get(name, in: directory) }
            guard let shard = Self.mergedShard(name, deviceName: deviceName, local: local, previous: previous,
                                              localQuota: localQuota, supersededRequestIDs: supersededRequestIDs)
            else { return previous }

            var headers = ["Content-Type": "application/json; charset=utf-8"]
            if let previous {
                guard let etag = Self.strongETag(previous.etag) else {
                    throw WebDAVError.missingStrongETag(name.filename)
                }
                headers["If-Match"] = etag
            } else {
                headers["If-None-Match"] = "*"
            }
            let response = try await publishBody(shard, name: name, to: url, headers: headers)
            if [200, 201, 204].contains(response.statusCode) {
                return RemoteShard(shard: shard, etag: response.value(forHTTPHeaderField: "ETag"), needsRedaction: false)
            }
            if ![409, 412].contains(response.statusCode) { throw WebDAVError.http("PUT", response.statusCode) }
        }
        throw WebDAVError.contention(name.filename)
    }

    private static func mergedShard(_ name: ShardName, deviceName: String, local: [UsageRequest], previous: RemoteShard?,
                                    localQuota: [QuotaWireObservation], supersededRequestIDs: Set<String>) -> Shard? {
        // Keep row storage shared until an actual write is required. A position
        // index is much smaller than a dictionary that copies every request.
        var rows = previous?.shard.requests ?? []
        let oldCount = rows.count
        if !supersededRequestIDs.isEmpty, rows.contains(where: { supersededRequestIDs.contains($0.id) }) {
            rows.removeAll { supersededRequestIDs.contains($0.id) }
        }
        var rowsChanged = rows.count != oldCount
        if !local.isEmpty {
            var index: [String: Int] = [:]
            index.reserveCapacity(rows.count)
            for (position, row) in rows.enumerated() { index[row.id] = position }
            for candidate in local {
                if let position = index[candidate.id] {
                    let remote = rows[position]
                    let localRow = candidate.preservingEvidence(from: remote)
                    if remote == localRow { continue }
                    var normalized = localRow
                    // Compare at wire precision so sub-millisecond differences never cause a repeated PUT.
                    if wireDate.string(from: remote.timestamp) == wireDate.string(from: localRow.timestamp) {
                        normalized.timestamp = remote.timestamp
                    }
                    if remote == normalized { continue }
                    rows[position] = localRow
                } else {
                    index[candidate.id] = rows.count
                    rows.append(candidate)
                }
                rowsChanged = true
            }
        }
        var quota = previous?.shard.quotaObservations
        var quotaChanged = false
        if !localQuota.isEmpty {
            var indexed = Dictionary(uniqueKeysWithValues: (quota ?? []).map { (quotaKey($0), $0) })
            for sample in localQuota {
                let key = quotaKey(sample)
                if let old = indexed[key], quotaEquivalent(old, sample) { continue }
                indexed[key] = sample
                quotaChanged = true
            }
            if quotaChanged { quota = indexed.sorted { $0.key < $1.key }.map(\.value) }
        }
        if let previous, !rowsChanged, !quotaChanged, !previous.needsRedaction, previous.shard.deviceName == deviceName { return nil }
        if previous == nil && rows.isEmpty && (quota?.isEmpty ?? true) { return nil }
        // Unchanged rows may come from a producer that didn't sort its shard.
        // Leave them alone unless reconciliation actually changed the rows.
        if rowsChanged { rows.sort { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) } }
        return Shard(schemaVersion: 1, deviceID: name.deviceID, deviceName: deviceName, month: name.month,
                     updatedAt: Date(), requests: rows, quotaObservations: quota?.isEmpty == false ? quota : nil)
    }

    private func publishBody(_ shard: Shard, name: ShardName, to url: URL, headers: [String: String]) async throws -> HTTPURLResponse {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMoon-WebDAV-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let body = temporary.appendingPathComponent("shard.json")
        guard FileManager.default.createFile(atPath: body.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: body)
        do {
            var writer = WireJSONWriter(handle: handle, limit: (name.filename, Self.maxBytes))
            try writer.encodeShard(shard)
            try writer.flush()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return try await upload(body, to: url, headers: headers)
    }

    fileprivate static let shardKeys: Set<String> = ["schemaVersion", "deviceID", "deviceName", "month", "updatedAt", "requests", "quotaObservations"]
    fileprivate static let quotaKeys: Set<String> = [
        "agent", "account", "windowID", "windowLabel", "observedAt", "usedPercent", "resetsAt", "durationSeconds", "plan",
    ]
    fileprivate static let requestKeys: Set<String> = [
        "id", "sessionID", "deviceID", "agent", "timestamp", "requestedModel", "sentModel", "provider",
        "providerID", "account", "accountEvidence", "loginMethod", "loginMethodEvidence", "sessionCreatorAccountID", "sessionCreatorAccountEmail",
        "reasoningEffort", "serviceTier", "requestedServiceTier", "sentServiceTier", "actualServiceTierEvidence",
        "status", "httpStatusCode", "message", "durationMS", "ttftMS", "timingSource", "estimatedDurationMS", "estimatedTimingSource",
        "inputTokens", "outputTokens", "cacheReadTokens",
        "cacheWriteTokens", "reasoningTokens", "source", "channel", "cacheWrite5mTokens", "cacheWrite1hTokens", "cpaKeyID", "cpaKeyLabel",
    ]

    // Date.ISO8601FormatStyle can truncate one millisecond when formatting its own parsed value.
    // A POSIX DateFormatter rounds consistently, so downloaded timestamps encode back to the same bytes.
    private static let wireDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    fileprivate static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(wireDate.string(from: date))
        }
        return encoder
    }

    fileprivate static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            if text.hasSuffix("Z") {
                if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
                if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ISO 8601 timestamp")
        }
        return decoder
    }

    fileprivate static func isValid(_ row: UsageRequest) -> Bool {
        row.isValid && !row.status.isEmpty && (row.reasoningTokens ?? 0) <= row.outputTokens &&
        [row.inputTokens, row.outputTokens, row.cacheReadTokens, row.cacheWriteTokens,
         row.reasoningTokens ?? 0, row.cacheWrite5mTokens ?? 0, row.cacheWrite1hTokens ?? 0]
            .allSatisfy { $0 <= 1_000_000_000_000 }
    }

    fileprivate static func isValid(_ shard: Shard, for name: ShardName) -> Bool {
        let quota = shard.quotaObservations ?? []
        guard quota.allSatisfy({ $0.isValid && decodedMonth(for: $0.observedAt) == name.month }),
              Set(quota.map(quotaKey)).count == quota.count else { return false }
        return shard.schemaVersion == 1 && shard.deviceID == name.deviceID && shard.month == name.month
            && !shard.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Set(shard.requests.map(\.id)).count == shard.requests.count
            && shard.requests.allSatisfy {
                $0.deviceID == name.deviceID && isValid($0) && decodedMonth(for: $0.timestamp) == name.month
            }
    }

    fileprivate struct QuotaKey: Hashable, Comparable {
        let agent: String
        let account: String
        let windowID: String
        let observedAt: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.observedAt, lhs.agent, lhs.account, lhs.windowID) < (rhs.observedAt, rhs.agent, rhs.account, rhs.windowID)
        }
    }

    fileprivate static func quotaKey(_ sample: QuotaWireObservation) -> QuotaKey {
        .init(agent: sample.agent.rawValue, account: sample.account, windowID: sample.windowID,
              observedAt: wireDate.string(from: sample.observedAt))
    }

    private static func quotaEquivalent(_ old: QuotaWireObservation, _ new: QuotaWireObservation) -> Bool {
        // The key already matched the time rounded to wire precision.
        old.windowLabel == new.windowLabel && old.usedPercent == new.usedPercent
            && old.durationSeconds == new.durationSeconds && old.plan == new.plan
            && old.resetsAt.map { wireDate.string(from: $0) } == new.resetsAt.map { wireDate.string(from: $0) }
    }

    fileprivate static func strongETag(_ value: String?) -> String? {
        guard let value, value.utf8.count >= 2, value.utf8.first == 34, value.utf8.last == 34,
              value.utf8.dropFirst().dropLast().allSatisfy({ $0 == 33 || (35...126).contains($0) || $0 >= 128 })
        else { return nil }
        return value
    }

    private static func month(for date: Date) -> String {
        String(wireDate.string(from: date).prefix(7))
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    fileprivate static func decodedMonth(for date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

private final class DAVSession: Sendable {
    let value: URLSession
    let decoder = WireShardDecoder()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        value = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { value.finishTasksAndInvalidate() }
}

/// Keep network reads concurrent, but bound expensive decoding to one lane.
private actor WireShardDecoder {
    private let value = WebDAVClient.decoder()

    func decode(file: URL, name: ShardName, inspectLegacyKeys: Bool) throws -> WireShardReader {
        try Task.checkCancellation()
        // The rows own their strings; do not retain the interner after a decode.
        value.userInfo[UsageStringInterner.key] = UsageStringInterner()
        defer { value.userInfo.removeValue(forKey: UsageStringInterner.key) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return try WireShardReader.read(data, range: 0..<data.count, name: name,
                                        inspectLegacyKeys: inspectLegacyKeys, decoder: value)
    }
}

private struct WireJSONMembers {
    let data: Data
    let decoder: JSONDecoder
    let members: [String: Range<Int>]

    init(_ data: Data, range: Range<Int>, decoder: JSONDecoder) throws {
        self.data = data
        self.decoder = decoder
        members = try JSONMemberSlices.members(in: data, range: range)
    }

    var malformed: DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid WebDAV JSON object"))
    }

    func requiredRange(_ name: String) throws -> Range<Int> {
        guard let range = members[name] else { throw malformed }
        return range
    }

    func value<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try decode(type, at: requiredRange(name))
    }

    func optional<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        guard let range = members[name] else { return nil }
        return try decode(T?.self, at: range)
    }

    func decode<T: Decodable>(_ type: T.Type, at range: Range<Int>) throws -> T {
        try decoder.decode(type, from: JSONMemberSlices.slice(in: data, range: range))
    }

    func isNull(_ range: Range<Int>) -> Bool {
        data[data.startIndex + range.lowerBound] == 0x6e // n
    }
}

private struct WireShardReader {
    let shard: Shard
    let needsRedaction: Bool

    static func read(_ data: Data, range: Range<Int>, name: ShardName, inspectLegacyKeys: Bool,
                     decoder: JSONDecoder) throws -> Self {
        do {
            return try readValidated(data, range: range, name: name, inspectLegacyKeys: inspectLegacyKeys, decoder: decoder)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.invalidShard(name.filename)
        }
    }

    private static func readValidated(_ data: Data, range: Range<Int>, name: ShardName, inspectLegacyKeys: Bool,
                                      decoder: JSONDecoder) throws -> Self {
        let header = try WireJSONMembers(data, range: range, decoder: decoder)
        let version = try header.value(Int.self, "schemaVersion")
        guard version == 1 else { throw WebDAVError.unsupportedSchema(name.filename, version) }
        let deviceID = try header.value(String.self, "deviceID")
        let deviceName = try header.value(String.self, "deviceName")
        let month = try header.value(String.self, "month")
        let updatedAt = try header.value(Date.self, "updatedAt")
        guard deviceID == name.deviceID, month == name.month,
              !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebDAVError.invalidShard(name.filename)
        }
        var redact = inspectLegacyKeys && !WebDAVClient.shardKeys.isSuperset(of: header.members.keys)
        var rows: [UsageRequest] = []
        var rowIDs: Set<String> = []
        let requestRange = try header.requiredRange("requests")
        // Avoid repeated reallocation for high-volume shards while capping the
        // initial reserve so an atypically large string can't amplify memory.
        rows.reserveCapacity(min(16_384, requestRange.count / 550))
        try JSONMemberSlices.forEachElement(in: data, range: requestRange) { range in
            try autoreleasepool {
                if rows.count.isMultiple(of: 256) { try Task.checkCancellation() }
                if inspectLegacyKeys && !redact {
                    redact = try !WebDAVClient.requestKeys.isSuperset(of: JSONMemberSlices.members(in: data, range: range).keys)
                }
                let row = try header.decode(UsageRequest.self, at: range)
                guard row.deviceID == deviceID, WebDAVClient.isValid(row),
                      WebDAVClient.decodedMonth(for: row.timestamp) == month, rowIDs.insert(row.id).inserted else {
                    throw WebDAVError.invalidShard(name.filename)
                }
                rows.append(row)
            }
        }
        var quota: [QuotaWireObservation]?
        if let range = header.members["quotaObservations"], !header.isNull(range) {
            var samples: [QuotaWireObservation] = []
            var keys: Set<WebDAVClient.QuotaKey> = []
            try JSONMemberSlices.forEachElement(in: data, range: range) { range in
                try autoreleasepool {
                    if samples.count.isMultiple(of: 256) { try Task.checkCancellation() }
                    if inspectLegacyKeys && !redact {
                        redact = try !WebDAVClient.quotaKeys.isSuperset(of: JSONMemberSlices.members(in: data, range: range).keys)
                    }
                    let sample = try header.decode(QuotaWireObservation.self, at: range)
                    guard sample.isValid, WebDAVClient.decodedMonth(for: sample.observedAt) == month,
                          keys.insert(WebDAVClient.quotaKey(sample)).inserted else {
                        throw WebDAVError.invalidShard(name.filename)
                    }
                    samples.append(sample)
                }
            }
            quota = samples
        }
        return Self(shard: Shard(schemaVersion: version, deviceID: deviceID, deviceName: deviceName,
                                month: month, updatedAt: updatedAt, requests: rows, quotaObservations: quota),
                    needsRedaction: redact)
    }
}

private struct WireJSONWriter {
    private let handle: FileHandle
    private let limit: (name: String, bytes: Int)?
    private let encoder = WebDAVClient.encoder()
    private var buffer = Data()
    private var bytesWritten = 0

    init(handle: FileHandle, limit: (String, Int)? = nil) {
        self.handle = handle
        self.limit = limit
        buffer.reserveCapacity(64 * 1024)
    }

    mutating func write(_ text: String) throws { try append(Data(text.utf8)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try autoreleasepool { try append(encoder.encode(value)) }
    }

    private mutating func append(_ data: Data) throws {
        if let limit, bytesWritten + buffer.count + data.count > limit.bytes {
            throw WebDAVError.oversized(limit.name)
        }
        if buffer.count + data.count >= 64 * 1024 { try flush() }
        if data.count >= 64 * 1024 {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } else {
            buffer.append(data)
        }
    }

    mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try Task.checkCancellation()
        try handle.write(contentsOf: buffer)
        bytesWritten += buffer.count
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func encodeShard(_ shard: Shard) throws {
        try write("{\"deviceID\":")
        try encode(shard.deviceID)
        try write(",\"deviceName\":")
        try encode(shard.deviceName)
        try write(",\"month\":")
        try encode(shard.month)
        if let quota = shard.quotaObservations {
            try write(",\"quotaObservations\":")
            try encodeArray(quota)
        }
        try write(",\"requests\":")
        try encodeArray(shard.requests)
        try write(",\"schemaVersion\":")
        try encode(shard.schemaVersion)
        try write(",\"updatedAt\":")
        try encode(shard.updatedAt)
        try write("}")
    }

    private mutating func encodeArray<T: Encodable>(_ values: [T]) throws {
        try write("[")
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if index != 0 { try write(",") }
            try encode(value)
        }
        try write("]")
    }
}

fileprivate struct Shard: Codable, Sendable {
    let schemaVersion: Int
    let deviceID: String
    let deviceName: String
    let month: String
    let updatedAt: Date
    let requests: [UsageRequest]
    var quotaObservations: [QuotaWireObservation]? = nil
}

fileprivate struct RemoteShard: Codable, Sendable {
    let shard: Shard
    let etag: String?
    let needsRedaction: Bool
}

private enum ReadOutcome: Sendable {
    case read(RemoteShard?)
    case failed(RemoteShard?, String)
}

private struct ListedShard: Sendable {
    let name: ShardName
    let etag: String?
}

fileprivate struct ShardName: Hashable, Comparable, Sendable {
    let deviceID: String
    let month: String

    init(deviceID: String, month: String) {
        self.deviceID = deviceID
        self.month = month
    }

    init?(filename: String) {
        guard filename.utf8.count == 50, filename.hasSuffix(".json") else { return nil }
        let deviceID = String(filename.prefix(36))
        let remainder = filename.dropFirst(36).dropLast(5)
        guard let uuid = UUID(uuidString: deviceID), deviceID == uuid.uuidString.lowercased(), remainder.hasPrefix("--") else {
            return nil
        }
        let month = String(remainder.dropFirst(2))
        guard month.range(of: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else { return nil }
        self.deviceID = deviceID
        self.month = month
    }

    var filename: String { "\(deviceID)--\(month).json" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.deviceID, lhs.month) < (rhs.deviceID, rhs.month)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class DirectoryListing: NSObject, XMLParserDelegate {
    private struct Element: Equatable {
        let name: String
        let namespace: String?

        init(_ name: String, _ namespace: String? = "DAV:") {
            self.name = name
            self.namespace = namespace
        }
    }

    private static let response = [Element("multistatus"), Element("response")]
    private static let responseHref = response + [Element("href")]
    private static let propstat = response + [Element("propstat")]
    private static let propstatStatus = propstat + [Element("status")]
    private static let propstatETag = propstat + [Element("prop"), Element("getetag")]
    private var stack: [Element] = []
    private var href = ""
    private var propETag = ""
    private var propStatus = ""
    private var successfulETags: Set<String> = []
    private(set) var responses: [(href: String, etag: String?)] = []
    private(set) var isDAV = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        let element = Element(elementName, namespaceURI)
        if stack.isEmpty { isDAV = element == Element("multistatus") }
        stack.append(element)
        if stack == Self.response {
            href = ""
            successfulETags = []
        } else if stack == Self.propstat {
            propETag = ""
            propStatus = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if stack == Self.responseHref { href += string }
        if stack == Self.propstatETag { propETag += string }
        if stack == Self.propstatStatus { propStatus += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        if stack == Self.propstat {
            let status = propStatus.split(whereSeparator: \.isWhitespace)
            let etag = propETag.trimmingCharacters(in: .whitespacesAndNewlines)
            if status.count >= 2, status[0].hasPrefix("HTTP/"), status[1] == "200", !etag.isEmpty {
                successfulETags.insert(etag)
            }
        } else if stack == Self.response {
            let url = href.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                responses.append((url, successfulETags.count == 1 ? successfulETags.first : nil))
            }
        }
        _ = stack.popLast()
    }
}
