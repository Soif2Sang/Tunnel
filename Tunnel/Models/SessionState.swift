import Foundation

enum FailureReason: Equatable, Sendable {
    case localPortInUse(Int)
    case authenticationFailed
    case kubectlNotFound
    case serviceNotFound
    case maxRetriesExceeded
    case userStopped
    case other(String)

    var description: String {
        switch self {
        case .localPortInUse(let p): return "Local port \(p) already in use"
        case .authenticationFailed: return "Authentication failed (oidc-login)"
        case .kubectlNotFound: return "kubectl binary not found"
        case .serviceNotFound: return "Service not found in cluster"
        case .maxRetriesExceeded: return "Max reconnection attempts exceeded"
        case .userStopped: return "Stopped by user"
        case .other(let s): return s
        }
    }
}

enum SessionState: Equatable, Sendable {
    case idle
    case connecting
    case running(since: Date, localBinding: String)
    case reconnecting(attempt: Int, nextAttemptAt: Date, lastError: String)
    case failed(reason: FailureReason)

    var isActive: Bool {
        switch self {
        case .connecting, .running, .reconnecting: return true
        case .idle, .failed: return false
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .running: return "Running"
        case .reconnecting(let attempt, _, _): return "Reconnecting (#\(attempt))"
        case .failed(let reason): return "Failed: \(reason.description)"
        }
    }
}
