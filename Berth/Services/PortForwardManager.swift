import Foundation

/// Orchestrates all port-forward sessions: start/stop, auto-restart with bounded backoff,
/// pre-flight port-conflict detection.
actor PortForwardManager {
    private let client: KubectlClient
    private let portChecker: LocalPortChecker
    private var sessions: [UUID: PortForwardSession] = [:]
    private var restartTasks: [UUID: Task<Void, Never>] = [:]
    private var attemptCounters: [UUID: Int] = [:]

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
        // Pre-flight: local port available?
        if let pid = await portChecker.processUsing(port: forward.localPort), pid != currentSessionPID(for: forward.id) {
            await emitState(forward.id, .failed(reason: .localPortInUse(forward.localPort)))
            return
        }

        // Cancel any pending restart.
        restartTasks[forward.id]?.cancel()
        restartTasks.removeValue(forKey: forward.id)

        // Stop any previous session.
        if let existing = sessions[forward.id] {
            await existing.stop(reason: .userStopped)
        }
        attemptCounters[forward.id] = 0

        let session = PortForwardSession(forward: forward, client: client)
        await setupCallbacks(on: session)
        sessions[forward.id] = session
        await session.start()
    }

    /// Stop a forward (user-initiated). Cancels any pending restart.
    func stop(id: UUID) async {
        restartTasks[id]?.cancel()
        restartTasks.removeValue(forKey: id)
        attemptCounters[id] = 0
        if let session = sessions[id] {
            await session.stop(reason: .userStopped)
        }
        sessions.removeValue(forKey: id)
    }

    func stopAll() async {
        let ids = Array(sessions.keys)
        for id in ids { await stop(id: id) }
    }

    /// Final shutdown: cancels all restart timers, terminates every kubectl child,
    /// and waits up to ~3s for them to exit before SIGKILLing.
    func shutdown() async {
        isShuttingDown = true

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

    private func setupCallbacks(on session: PortForwardSession) async {
        // The session calls these on the main actor.
        session.onLogLine = { [weak self] id, line in
            Task { await self?.forwardLogLine(id: id, line: line) }
        }
        session.onStateChange = { [weak self] id, state in
            Task { await self?.handleStateChange(id: id, state: state) }
        }
    }

    private func forwardLogLine(id: UUID, line: String) async {
        let handler = onLogLine
        if let handler {
            await MainActor.run { handler(id, line) }
        }
    }

    private func handleStateChange(id: UUID, state: SessionState) async {
        // Re-publish to UI.
        let handler = onStateChange
        if let handler {
            await MainActor.run { handler(id, state) }
        }

        // If a session moved to .reconnecting (terminated unexpectedly), schedule the next attempt.
        if case .reconnecting(_, _, let lastError) = state, let session = sessions[id] {
            await scheduleReconnect(for: session.forward, lastError: lastError)
        }

        // Reset counter on a successful run.
        if case .running = state {
            attemptCounters[id] = 0
        }
    }

    private func scheduleReconnect(for forward: PortForward, lastError: String) async {
        if isShuttingDown { return }
        let attempt = (attemptCounters[forward.id] ?? 0) + 1
        attemptCounters[forward.id] = attempt
        if attempt > maxAttempts {
            await emitState(forward.id, .failed(reason: .maxRetriesExceeded))
            return
        }
        let delay = backoffSchedule[min(attempt - 1, backoffSchedule.count - 1)]
        let nextAt = Date().addingTimeInterval(delay)
        await emitState(forward.id, .reconnecting(attempt: attempt, nextAttemptAt: nextAt, lastError: lastError))

        restartTasks[forward.id]?.cancel()
        restartTasks[forward.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.start(forward: forward)
        }
    }

    private func emitState(_ id: UUID, _ state: SessionState) async {
        let handler = onStateChange
        if let handler {
            await MainActor.run { handler(id, state) }
        }
    }
}
