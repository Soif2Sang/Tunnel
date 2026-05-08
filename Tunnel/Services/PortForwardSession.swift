import Foundation

/// One running `kubectl port-forward` invocation. Owns its Process, parses stderr,
/// and reports state via `onStateChange`.
final class PortForwardSession: @unchecked Sendable {
    let id: UUID
    let forward: PortForward
    private let client: KubectlClient

    private let stateLock = NSLock()
    private var _state: SessionState = .idle
    var state: SessionState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private(set) var process: Process?
    private(set) var streamTask: Task<Void, Never>?
    private(set) var logBuffer: [String] = []
    private let logLock = NSLock()
    private let logCapacity = 200

    /// Set by manager. Called on every state mutation, on the main actor.
    var onStateChange: (@MainActor @Sendable (UUID, SessionState) -> Void)?
    /// Called when stderr emits a line (for live log views).
    var onLogLine: (@MainActor @Sendable (UUID, String) -> Void)?

    init(forward: PortForward, client: KubectlClient = .shared) {
        self.id = forward.id
        self.forward = forward
        self.client = client
    }

    /// Launch the kubectl port-forward subprocess and start observing stderr.
    /// Caller is responsible for pre-flight checks (port conflict, etc.).
    func start() async {
        await setState(.connecting)
        do {
            let args = [
                "--context", forward.context,
                "-n", forward.namespace,
                "port-forward",
                "services/\(forward.serviceName)",
                "\(forward.localPort):\(forward.remotePort)",
            ]
            let (process, stream) = try await client.streaming(args)
            self.process = process

            self.streamTask = Task { [weak self] in
                guard let self else { return }
                for await event in stream {
                    await self.handle(event)
                }
            }
        } catch KubectlError.notFound {
            await setState(.failed(reason: .kubectlNotFound))
        } catch {
            await setState(.failed(reason: .other("\(error)")))
        }
    }

    /// Terminate the process gracefully (SIGTERM, then SIGKILL after 2s).
    func stop(reason: FailureReason = .userStopped) async {
        let proc = self.process
        self.process = nil
        if let proc, proc.isRunning {
            proc.terminate()
            // Give it 2s, then kill.
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        streamTask?.cancel()
        if reason == .userStopped {
            await setState(.idle)
        } else {
            await setState(.failed(reason: reason))
        }
    }

    func recentLogs() -> [String] {
        logLock.lock(); defer { logLock.unlock() }
        return logBuffer
    }

    // MARK: - private

    private func handle(_ event: KubectlEvent) async {
        switch event {
        case .stdoutLine(let line), .stderrLine(let line):
            appendLog(line)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.onLogLine?(self.id, line)
            }
            interpret(line: line)
        case .terminated(let status):
            await handleTermination(status: status)
        }
    }

    private func interpret(line: String) {
        let lower = line.lowercased()
        if lower.contains("forwarding from") {
            // example: "Forwarding from 127.0.0.1:3100 -> 3000"
            let binding = extractBinding(from: line) ?? "127.0.0.1:\(forward.localPort)"
            Task { await setState(.running(since: Date(), localBinding: binding)) }
        } else if lower.contains("error: oidc-login") || lower.contains("oidc-login: error") {
            // Auth flow failure. Propagate; manager decides whether to retry.
        } else if lower.contains("lost connection") || lower.contains("error forwarding") {
            // Will be handled on process termination as well; nothing to do here.
        }
    }

    private func extractBinding(from line: String) -> String? {
        // `Forwarding from 127.0.0.1:3100 -> 3000`
        guard let fromRange = line.range(of: "Forwarding from ") else { return nil }
        let after = line[fromRange.upperBound...]
        if let arrow = after.range(of: " ") {
            return String(after[..<arrow.lowerBound])
        }
        return String(after)
    }

    private func appendLog(_ line: String) {
        logLock.lock(); defer { logLock.unlock() }
        logBuffer.append(line)
        if logBuffer.count > logCapacity {
            logBuffer.removeFirst(logBuffer.count - logCapacity)
        }
    }

    private func handleTermination(status: Int32) async {
        let snapshot = self.state
        // If user already stopped or we're failed, ignore.
        switch snapshot {
        case .idle, .failed:
            return
        default:
            break
        }
        let recent = recentLogs().suffix(5).joined(separator: " | ")
        // Check if it was an auth failure first.
        if recent.lowercased().contains("oidc-login") && status != 0 {
            await setState(.failed(reason: .authenticationFailed))
            return
        }
        // Bind failure on local port.
        if recent.lowercased().contains("address already in use") || recent.lowercased().contains("bind: address already in use") {
            await setState(.failed(reason: .localPortInUse(forward.localPort)))
            return
        }
        // Service-not-found
        if recent.lowercased().contains("services") && recent.lowercased().contains("not found") {
            await setState(.failed(reason: .serviceNotFound))
            return
        }
        // Otherwise: signal the manager to schedule a reconnect.
        // The manager listens to state-change callbacks; when it sees a non-running terminating event
        // it will move us into .reconnecting itself.
        await setState(.reconnecting(attempt: 0, nextAttemptAt: Date(), lastError: recent))
    }

    private func setState(_ new: SessionState) async {
        stateLock.withLock { _state = new }
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.onStateChange?(self.id, new)
        }
    }
}
