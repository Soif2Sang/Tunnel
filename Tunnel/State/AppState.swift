import Foundation
import Observation

/// Single source of truth for the UI. MainActor-bound; mutations from the manager actor
/// are routed back to the main actor before mutating state.
@MainActor
@Observable
final class AppState {
    // MARK: - persisted
    var forwards: [PortForward] = []

    // MARK: - runtime
    var contexts: [KubeContext] = []
    var states: [UUID: SessionState] = [:]
    var contextRefreshErrors: [String: String] = [:]
    var lastError: String?
    var hasBootstrapped: Bool = false
    var hasImportedZshrc: Bool = false

    // MARK: - search
    var searchQuery: String = ""
    var searchResults: [KubeService] = []
    var lastCatalogRefresh: Date?

    // MARK: - settings
    var kubectlPath: String = KubectlClient.detectKubectlPath()
    var extraPath: String = KubectlClient.defaultExtraPath()

    // MARK: - logs
    var liveLogs: [UUID: [String]] = [:]
    private let logCapacity = 200

    // MARK: - menu bar broadcast

    enum StatusTone { case green, yellow, red, grey }
    struct StatusSummary: Sendable { let tone: StatusTone; let runningCount: Int; let failedCount: Int }
    var summaryUpdates: AsyncStream<StatusSummary>
    private let summaryContinuation: AsyncStream<StatusSummary>.Continuation

    // MARK: - dependencies
    private let store = ConfigStore()
    private let manager = PortForwardManager()
    private let catalog = ServiceCatalog()
    private let contextLoader = KubeContextLoader()

    init() {
        var cont: AsyncStream<StatusSummary>.Continuation!
        self.summaryUpdates = AsyncStream { c in cont = c }
        self.summaryContinuation = cont
    }

    // MARK: - bootstrap / shutdown

    func bootstrap() async {
        await wireManagerCallbacks()

        // Load saved forwards.
        do {
            self.forwards = try await store.load()
        } catch {
            lastError = "Failed to load forwards: \(error)"
        }
        // Initial state for every saved forward = idle.
        for f in forwards where states[f.id] == nil {
            states[f.id] = .idle
        }
        hasBootstrapped = true

        await refreshContexts()
        // Kick off catalog refresh in background; don't block UI.
        Task { await refreshCatalog() }

        // Auto-start.
        for f in forwards where f.autoStart {
            await start(forward: f)
        }
        publishSummary()
    }

    func shutdown() async {
        await manager.shutdown()
    }

    // MARK: - context / catalog

    func refreshContexts() async {
        do {
            self.contexts = try await contextLoader.loadContexts()
        } catch {
            lastError = "Failed to load contexts: \(error)"
        }
    }

    func refreshCatalog(force: Bool = false) async {
        let ctxs = self.contexts
        let results = await catalog.refreshAll(contexts: ctxs, force: force)
        var errs: [String: String] = [:]
        for (name, result) in results {
            if case .failure(let err) = result {
                errs[name] = "\(err)"
            }
        }
        self.contextRefreshErrors = errs
        self.lastCatalogRefresh = Date()
        await runSearch()
    }

    func runSearch() async {
        let q = searchQuery
        self.searchResults = await catalog.search(q, limit: 200)
    }

    // MARK: - forward CRUD

    func add(_ pf: PortForward) async {
        forwards.append(pf)
        states[pf.id] = .idle
        await persist()
    }

    func update(_ pf: PortForward) async {
        if let idx = forwards.firstIndex(where: { $0.id == pf.id }) {
            forwards[idx] = pf
        }
        await persist()
    }

    func delete(id: UUID) async {
        await manager.stop(id: id)
        forwards.removeAll { $0.id == id }
        states.removeValue(forKey: id)
        liveLogs.removeValue(forKey: id)
        await persist()
        publishSummary()
    }

    func setAutoStart(id: UUID, _ value: Bool) async {
        if let idx = forwards.firstIndex(where: { $0.id == id }) {
            forwards[idx].autoStart = value
            await persist()
        }
    }

    private func persist() async {
        let snapshot = forwards
        do {
            try await store.save(snapshot)
        } catch {
            lastError = "Failed to save: \(error)"
        }
    }

    // MARK: - lifecycle commands

    func start(forward: PortForward) async {
        await manager.start(forward: forward)
    }

    func stop(id: UUID) async {
        await manager.stop(id: id)
    }

    /// Clear a failed forward's state back to .idle (also cancels any pending
    /// reconnect timers and forgets the attempt counter for the next start).
    func acknowledgeFailure(id: UUID) async {
        await manager.stop(id: id)
    }

    /// Look up which process is currently holding the local port of a saved forward.
    func portHolder(forwardID: UUID) async -> PortHolder? {
        guard let pf = forwards.first(where: { $0.id == forwardID }) else { return nil }
        return await LocalPortChecker().holder(port: pf.localPort)
    }

    /// Kill whichever process is bound to the saved forward's local port,
    /// then start the forward. Returns true if the forward was (re)started.
    @discardableResult
    func freePortAndRetry(forwardID: UUID) async -> Bool {
        guard let pf = forwards.first(where: { $0.id == forwardID }) else { return false }
        let freed = await LocalPortChecker().killHolder(port: pf.localPort)
        if freed {
            await start(forward: pf)
            return true
        } else {
            lastError = "Could not free port \(pf.localPort)"
            return false
        }
    }

    func startAll() async {
        for f in forwards {
            await manager.start(forward: f)
        }
    }

    func stopAll() async {
        await manager.stopAll()
    }

    // MARK: - imports

    /// Returns the imported aliases (some may have parse errors). Caller decides what to add.
    func loadZshrcImports() -> [ImportedAlias] {
        let defaultCtx = contexts.first(where: \.isCurrent)?.name ?? contexts.first?.name ?? ""
        return ZshrcImporter.importFromZshrc(defaultContext: defaultCtx)
    }

    func importAliases(_ aliases: [ImportedAlias]) async {
        for alias in aliases {
            guard let pf = alias.parsed else { continue }
            // Skip if a forward with same target already exists.
            let exists = forwards.contains { other in
                other.context == pf.context && other.namespace == pf.namespace &&
                other.serviceName == pf.serviceName && other.localPort == pf.localPort
            }
            if !exists {
                await add(pf)
            }
        }
        hasImportedZshrc = true
    }

    // MARK: - manager callbacks

    private func wireManagerCallbacks() async {
        await manager.setStateChangeHandler { [weak self] id, state in
            Task { @MainActor in
                self?.states[id] = state
                self?.publishSummary()
            }
        }
        await manager.setLogLineHandler { [weak self] id, line in
            Task { @MainActor in
                self?.appendLog(id: id, line: line)
            }
        }
    }

    private func appendLog(id: UUID, line: String) {
        var lines = liveLogs[id] ?? []
        lines.append(line)
        if lines.count > logCapacity {
            lines.removeFirst(lines.count - logCapacity)
        }
        liveLogs[id] = lines
    }

    // MARK: - status summary

    func currentSummary() -> StatusSummary {
        var running = 0, failed = 0, connecting = 0
        for state in states.values {
            switch state {
            case .running: running += 1
            case .failed: failed += 1
            case .connecting, .reconnecting: connecting += 1
            case .idle: break
            }
        }
        let tone: StatusTone
        if failed > 0 { tone = .red }
        else if connecting > 0 { tone = .yellow }
        else if running > 0 { tone = .green }
        else { tone = .grey }
        return StatusSummary(tone: tone, runningCount: running, failedCount: failed)
    }

    private func publishSummary() {
        summaryContinuation.yield(currentSummary())
    }

    // MARK: - settings

    func updateKubectlPath(_ newPath: String) async {
        kubectlPath = newPath
        await KubectlClient.shared.setExecutablePath(newPath)
    }

    func updateExtraPath(_ newPath: String) async {
        extraPath = newPath
        await KubectlClient.shared.setExtraPath(newPath)
    }
}
