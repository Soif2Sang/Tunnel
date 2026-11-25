import Foundation

/// Orchestrates all port-forward sessions: start/stop, auto-restart with bounded backoff,
/// pre-flight port-conflict detection.
actor PortForwardManager {
    private let client: KubectlClient
    private let portChecker: LocalPortChecker
    private var sessions: [UUID: PortForwardSession] = [:]
    private var restartTasks: [UUID: Task<Void, Never>] = [:]
    private var attemptCounters: [UUID: Int] = [:]
    private var isLaunchingGCloudLogin = false
    private var gcloudLoginTask: Task<Void, Error>?
    private var gcloudAuthFailedIDs: Set<UUID> = []

    private let backoffSchedule: [TimeInterval] = [1, 2, 5, 10, 10, 10, 30, 30, 60, 60]
    private let maxAttempts: Int
    private var isShuttingDown: Bool = false

    var onStateChange: (@MainActor @Sendable (UUID, SessionState) -> Void)?
    var onLogLine: (@MainActor @Sendable (UUID, String) -> Void)?

    init(
        client: KubectlClient = .shared,
        portChecker: LocalPortChecker = LocalPortChecker(),
        maxAttempts: Int = 10
    ) {
        self.client = client
        self.portChecker = portChecker
        self.maxAttempts = maxAttempts
    }

    func setStateChangeHandler(_ handler: @MainActor @Sendable @escaping (UUID, SessionState) -> Void) {
        self.onStateChange = handler
    }

    func setLogLineHandler(_ handler: @MainActor @Sendable @escaping (UUID, String) -> Void) {
        self.onLogLine = handler
    }

    func currentState(for id: UUID) -> SessionState {
        sessions[id]?.state ?? .idle
    }

    func recentLogs(for id: UUID) -> [String] {
        sessions[id]?.recentLogs() ?? []
    }

    /// Start (or restart) a forward.
    func start(forward: PortForward) async {
        restartTasks.removeValue(forKey: forward.id)?.cancel()
        attemptCounters[forward.id] = 0
        await launch(forward: forward, replacing: sessions[forward.id])
    }

    private func launch(forward: PortForward, replacing previous: PortForwardSession?) async {
        guard !Task.isCancelled, !isShuttingDown, sessions[forward.id] === previous else { return }
        // Pre-flight: local port available?
        let pid = await portChecker.processUsing(port: forward.localPort)
        guard !Task.isCancelled, !isShuttingDown, sessions[forward.id] === previous else { return }
        if let pid, pid != currentSessionPID(for: forward.id) {
            await emitState(forward.id, .failed(reason: .localPortInUse(forward.localPort)))
            return
        }

        let session = PortForwardSession(forward: forward, client: client)
        setupCallbacks(on: session)
        sessions[forward.id] = session
        if let previous { await previous.stop(waitForExit: true) }
        await session.start()
    }

    /// Stop a forward (user-initiated). Cancels any pending restart.
    func stop(id: UUID) async {
        gcloudAuthFailedIDs.remove(id)
        restartTasks[id]?.cancel()
        restartTasks.removeValue(forKey: id)
        attemptCounters[id] = 0
        if let session = sessions.removeValue(forKey: id) { await session.stop() }
        if sessions[id] == nil { await emitState(id, .idle) }
    }

    func stopAll() async {
        let ids = Array(sessions.keys)
        for id in ids { await stop(id: id) }
    }

    /// Final shutdown: cancels all restart timers, terminates every forwarding child,
    /// and waits up to ~3s for them to exit before SIGKILLing.
    func shutdown() async {
        isShuttingDown = true
        gcloudLoginTask?.cancel()
        gcloudAuthFailedIDs.removeAll()

        // Cancel all pending restart timers first.
        for (_, task) in restartTasks { task.cancel() }
        restartTasks.removeAll()

        // Snapshot processes so we can wait on them outside actor isolation.
        let processes: [Process] = sessions.values.compactMap { $0.process }

        // Send SIGTERM to all.
        for proc in processes where proc.isRunning {
            proc.terminate()
        }

        // Wait up to ~2.5s for graceful exit.
        for _ in 0..<25 {
            if processes.allSatisfy({ !$0.isRunning }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Anything still alive gets SIGKILL.
        for proc in processes where proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }

        // Last check, brief.
        try? await Task.sleep(nanoseconds: 200_000_000)
        sessions.removeAll()
        attemptCounters.removeAll()
    }

    // MARK: - private

    private func currentSessionPID(for id: UUID) -> Int32? {
        guard let process = sessions[id]?.process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private func setupCallbacks(on session: PortForwardSession) {
        // The session calls these on the main actor.
        session.onLogLine = { [weak self, weak session] id, line in
            Task { await self?.forwardLogLine(id: id, line: line, source: session) }
        }
        session.onStateChange = { [weak self, weak session] id, state in
            Task { await self?.handleStateChange(id: id, state: state, source: session) }
        }
    }

    private func forwardLogLine(id: UUID, line: String, source: PortForwardSession?) async {
        guard let source, sessions[id] === source else { return }
        let handler = onLogLine
        if let handler {
            await MainActor.run { handler(id, line) }
        }
    }

    private func handleStateChange(id: UUID, state: SessionState, source: PortForwardSession?) async {
        guard !isShuttingDown, let source, sessions[id] === source, source.state == state else { return }
        // Re-publish to UI.
        let handler = onStateChange
        if let handler {
            await MainActor.run { handler(id, state) }
        }

        // If a session moved to .reconnecting (terminated unexpectedly), schedule the next attempt.
        guard sessions[id] === source, source.state == state else { return }
        if case .reconnecting(_, _, let lastError) = state {
            await scheduleReconnect(session: source, lastError: lastError)
        }

        // Reset counter on a successful run.
        if case .running = state {
            attemptCounters[id] = 0
        }

        if case .failed(reason: .gcloudAuthenticationRequired) = state {
            guard !isShuttingDown, sessions[id]?.state == state else { return }
            gcloudAuthFailedIDs.insert(id)
            await launchGCloudLoginIfNeeded()
        }
    }

    private func launchGCloudLoginIfNeeded() async {
        // Several auto-started forwards can fail together; only open one browser login.
        guard !isLaunchingGCloudLogin, !isShuttingDown else { return }
        isLaunchingGCloudLogin = true

        do {
            let path = await client.extraPath
            guard !isShuttingDown else {
                isLaunchingGCloudLogin = false
                return
            }
            let loginTask = Task {
                try await GCloudAuthLoginLauncher.runLogin(extraPath: path)
            }
            gcloudLoginTask = loginTask
            try await loginTask.value

            // Authentication completed. Retry every forward that failed while
            // this single login flow was in progress.
            let forwardsToRetry = gcloudAuthFailedIDs.compactMap { sessions[$0]?.forward }
            gcloudAuthFailedIDs.removeAll()
            isLaunchingGCloudLogin = false
            gcloudLoginTask = nil
            for forward in forwardsToRetry {
                guard !isShuttingDown else { break }
                guard sessions[forward.id]?.state == .failed(reason: .gcloudAuthenticationRequired) else { continue }
                await start(forward: forward)
            }
        } catch {
            isLaunchingGCloudLogin = false
            gcloudLoginTask = nil
            let failedIDs = gcloudAuthFailedIDs
            gcloudAuthFailedIDs.removeAll()
            guard !isShuttingDown else { return }
            for failedID in failedIDs {
                await emitState(
                    failedID,
                    .failed(reason: .other("Google Cloud login failed: \(error.localizedDescription)"))
                )
            }
        }
    }

    private func scheduleReconnect(session: PortForwardSession, lastError: String) async {
        if isShuttingDown { return }
        let forward = session.forward
        let attempt = (attemptCounters[forward.id] ?? 0) + 1
        attemptCounters[forward.id] = attempt
        if attempt > maxAttempts {
            await emitState(forward.id, .failed(reason: .maxRetriesExceeded))
            return
        }
        let delay = backoffSchedule[min(attempt - 1, backoffSchedule.count - 1)]
        let nextAt = Date().addingTimeInterval(delay)
        await emitState(forward.id, .reconnecting(attempt: attempt, nextAttemptAt: nextAt, lastError: lastError))
        guard !isShuttingDown, sessions[forward.id] === session else { return }

        restartTasks[forward.id]?.cancel()
        restartTasks[forward.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.launch(forward: forward, replacing: session)
        }
    }

    private func emitState(_ id: UUID, _ state: SessionState) async {
        let handler = onStateChange
        if let handler {
            await MainActor.run { handler(id, state) }
        }
    }
}
