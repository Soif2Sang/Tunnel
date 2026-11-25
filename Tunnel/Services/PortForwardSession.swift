import Foundation

/// One running Kubernetes or SSH forward. Owns its Process, observes output,
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

    private var _process: Process?
    var process: Process? { stateLock.withLock { _process } }
    private var streamTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var stopped = false
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

    /// Launch the forwarding subprocess and begin observing its state.
    /// Caller is responsible for pre-flight checks (port conflict, etc.).
    func start() async {
        await setState(.connecting)
        guard !stateLock.withLock({ stopped }) else { return }
        do {
            let (process, stream): (Process, AsyncStream<KubectlEvent>)
            if let ssh = forward.ssh, ssh.isValid {
                (process, stream) = try KubectlClient.streamSSH(
                    ssh.arguments(localPort: forward.localPort, remotePort: forward.remotePort)
                )
            } else if forward.ssh == nil, let context = forward.context,
                      let namespace = forward.namespace, let service = forward.serviceName {
                (process, stream) = try await client.streaming([
                    "--context", context, "-n", namespace, "port-forward", "services/\(service)",
                    "\(forward.localPort):\(forward.remotePort)",
                ])
            } else {
                await setState(.failed(reason: .other("Invalid forward target")))
                return
            }

            let attached = stateLock.withLock {
                guard !stopped else { return false }
                self._process = process
                self.streamTask = Task { [weak self] in
                    for await event in stream {
                        guard !Task.isCancelled, let self else { break }
                        await self.handle(event)
                    }
                }
                if forward.ssh != nil {
                    self.readinessTask = Task { [weak self] in
                        let checker = LocalPortChecker()
                        let pid = process.processIdentifier
                        while !Task.isCancelled, process.isRunning, let self {
                            if await checker.processUsing(port: self.forward.localPort, pid: pid, ipv4LoopbackOnly: true) == pid {
                                guard !Task.isCancelled, process.isRunning else { return }
                                await self.markRunning(binding: "127.0.0.1:\(self.forward.localPort)")
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(350))
                        }
                    }
                }
                return true
            }
            if !attached { Self.terminate(process) }
        } catch KubectlError.notFound {
            await setState(.failed(reason: .kubectlNotFound))
        } catch {
            await setState(.failed(reason: .other("\(error)")))
        }
    }

    /// Terminate the process gracefully (SIGTERM, then SIGKILL after 2s).
    func stop(reason: FailureReason = .userStopped, waitForExit: Bool = false) async {
        let proc = stateLock.withLock {
            stopped = true
            streamTask?.cancel()
            readinessTask?.cancel()
            let proc = _process
            _process = nil
            return proc
        }
        if let proc { Self.terminate(proc) }
        if waitForExit, let proc {
            for _ in 0..<90 {
                if !proc.isRunning || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        if reason == .userStopped {
            await setState(.idle, allowStopped: true)
        } else {
            await setState(.failed(reason: reason), allowStopped: true)
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
            if forward.ssh == nil, line.hasPrefix("Forwarding from ") {
                let binding = extractBinding(from: line) ?? "127.0.0.1:\(forward.localPort)"
                await markRunning(binding: binding)
            }
        case .terminated(let status):
            await handleTermination(status: status)
        }
    }

    private func markRunning(binding: String) async {
        await setState(.running(since: Date(), localBinding: binding), onlyWhileConnecting: true)
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
        let logs = recentLogs()
        let recent = logs.suffix(5).joined(separator: " | ")
        if forward.ssh != nil {
            await setState(Self.sshExitState(status: status, localPort: forward.localPort, logs: logs))
            return
        }
        let lower = logs.joined(separator: " | ").lowercased()
        // GKE's exec plugin cannot prompt for expired credentials when launched by the app.
        if status != 0,
           lower.contains("cannot prompt during non-interactive execution"),
           (lower.contains("gcloud.config.config-helper") || lower.contains("gke-gcloud-auth-plugin")) {
            await setState(.failed(reason: .gcloudAuthenticationRequired))
            return
        }
        // Check if it was an auth failure first.
        if lower.contains("oidc-login") && status != 0 {
            await setState(.failed(reason: .authenticationFailed))
            return
        }
        // Bind failure on local port.
        if lower.contains("address already in use") || lower.contains("bind: address already in use") {
            await setState(.failed(reason: .localPortInUse(forward.localPort)))
            return
        }
        // Service-not-found
        if lower.contains("services") && lower.contains("not found") {
            await setState(.failed(reason: .serviceNotFound))
            return
        }
        // Otherwise: signal the manager to schedule a reconnect.
        // The manager listens to state-change callbacks; when it sees a non-running terminating event
        // it will move us into .reconnecting itself.
        await setState(.reconnecting(attempt: 0, nextAttemptAt: Date(), lastError: recent))
    }

    static func sshExitState(status: Int32, localPort: Int, logs: [String]) -> SessionState {
        let lower = logs.joined(separator: "\n").lowercased()
        if lower.contains("address already in use") {
            return .failed(reason: .localPortInUse(localPort))
        }
        if lower.contains("permission denied") || lower.contains("host key verification failed")
            || lower.contains("remote host identification has changed") || lower.contains("bad configuration option") {
            let detail = logs.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "SSH setup failed"
            return .failed(reason: .other("\(detail) Check this host in Terminal."))
        }
        let message = logs.last ?? "SSH exited (code \(status))."
        return .reconnecting(attempt: 0, nextAttemptAt: Date(), lastError: message)
    }

    private func setState(_ new: SessionState, allowStopped: Bool = false, onlyWhileConnecting: Bool = false) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            let changed = self.stateLock.withLock {
                guard !self.stopped || allowStopped else { return false }
                guard !onlyWhileConnecting || self._state == .connecting else { return false }
                self._state = new
                return true
            }
            guard changed else { return }
            self.onStateChange?(self.id, new)
        }
    }
}
