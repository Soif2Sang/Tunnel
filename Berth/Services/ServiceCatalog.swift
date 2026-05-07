import Foundation

// Minimal Decodable shapes for `kubectl get services -A -o json`
private struct ServicesList: Decodable {
    let items: [Item]
    struct Item: Decodable {
        let metadata: Metadata
        let spec: Spec?
    }
    struct Metadata: Decodable {
        let name: String
        let namespace: String?
        let labels: [String: String]?
    }
    struct Spec: Decodable {
        let ports: [Port]?
    }
    struct Port: Decodable {
        let name: String?
        let port: Int
        let targetPort: TargetPort?
        let `protocol`: String?
    }
    enum TargetPort: Decodable {
        case int(Int)
        case string(String)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let i = try? container.decode(Int.self) { self = .int(i); return }
            if let s = try? container.decode(String.self) { self = .string(s); return }
            self = .string("")
        }
        var stringValue: String {
            switch self {
            case .int(let i): return String(i)
            case .string(let s): return s
            }
        }
    }
}

actor ServiceCatalog {
    private let client: KubectlClient
    private let cacheTTL: TimeInterval
    private var cache: [String: (fetchedAt: Date, services: [KubeService])] = [:]
    private(set) var unreachableContexts: Set<String> = []
    private(set) var lastError: [String: String] = [:]

    init(client: KubectlClient = .shared, cacheTTL: TimeInterval = 60) {
        self.client = client
        self.cacheTTL = cacheTTL
    }

    func cachedServices(for context: String) -> [KubeService] {
        cache[context]?.services ?? []
    }

    func allCachedServices() -> [KubeService] {
        cache.values.flatMap(\.services)
    }

    func isContextUnreachable(_ context: String) -> Bool {
        unreachableContexts.contains(context)
    }

    /// Refresh services for all the given contexts in parallel. Per-context failures are recorded but don't throw.
    @discardableResult
    func refreshAll(contexts: [KubeContext], force: Bool = false) async -> [String: Result<[KubeService], Error>] {
        var results: [String: Result<[KubeService], Error>] = [:]
        await withTaskGroup(of: (String, Result<[KubeService], Error>).self) { group in
            for ctx in contexts {
                group.addTask { [self] in
                    do {
                        let svcs = try await self.refresh(context: ctx.name, force: force)
                        return (ctx.name, .success(svcs))
                    } catch {
                        return (ctx.name, .failure(error))
                    }
                }
            }
            for await (name, result) in group {
                results[name] = result
            }
        }
        return results
    }

    @discardableResult
    func refresh(context: String, force: Bool = false) async throws -> [KubeService] {
        if !force, let cached = cache[context], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.services
        }
        do {
            let list: ServicesList = try await client.runJSON(
                ["--context", context, "--request-timeout", "10s", "get", "services", "-A", "-o", "json"],
                timeout: 15
            )
            let services = list.items.map { item in
                KubeService(
                    context: context,
                    namespace: item.metadata.namespace ?? "default",
                    name: item.metadata.name,
                    ports: (item.spec?.ports ?? []).map { p in
                        KubeServicePort(
                            name: p.name,
                            port: p.port,
                            targetPort: p.targetPort?.stringValue,
                            protocolName: p.`protocol`
                        )
                    },
                    labels: item.metadata.labels ?? [:]
                )
            }
            cache[context] = (Date(), services)
            unreachableContexts.remove(context)
            lastError.removeValue(forKey: context)
            return services
        } catch {
            unreachableContexts.insert(context)
            lastError[context] = "\(error)"
            throw error
        }
    }

    /// Fuzzy search across all cached services. Returns ranked matches.
    func search(_ query: String, limit: Int = 100) -> [KubeService] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = allCachedServices()
        if q.isEmpty {
            return Array(all.prefix(limit))
        }
        var scored: [(score: Int, svc: KubeService)] = []
        for svc in all {
            if let score = Self.fuzzyScore(needle: q, haystack: svc.name.lowercased()) {
                scored.append((score, svc))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.svc.name < rhs.svc.name
        }
        return scored.prefix(limit).map(\.svc)
    }

    /// Subsequence match. Higher score = better match. Bonuses: exact-substring, prefix, contiguous run.
    static func fuzzyScore(needle: String, haystack: String) -> Int? {
        if needle.isEmpty { return 0 }
        if haystack.contains(needle) {
            // big bonus for substring; even bigger for prefix
            return haystack.hasPrefix(needle) ? 1000 : 500 + (100 - min(haystack.count, 100))
        }
        // subsequence
        var hi = haystack.startIndex
        var matched = 0
        var run = 0
        var maxRun = 0
        for n in needle {
            var found = false
            while hi < haystack.endIndex {
                if haystack[hi] == n {
                    matched += 1
                    run += 1
                    maxRun = max(maxRun, run)
                    hi = haystack.index(after: hi)
                    found = true
                    break
                } else {
                    run = 0
                    hi = haystack.index(after: hi)
                }
            }
            if !found { return nil }
        }
        return matched * 10 + maxRun * 5
    }
}
