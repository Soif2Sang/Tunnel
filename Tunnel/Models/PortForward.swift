import Foundation

struct SSHForwardTarget: Codable, Hashable, Sendable {
    var host: String
    var remoteHost: String

    var isValid: Bool {
        // Accept OpenSSH host aliases, DNS names and IPv4 addresses without
        // accepting options, shell syntax or extra fields in the -L argument.
        Self.isHostName(host) && Self.isHostName(remoteHost)
    }

    func arguments(localPort: Int, remotePort: Int) -> [String] {
        [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            // Keep the listener owned by this process even if the alias uses multiplexing.
            "-o", "ControlPath=none",
            "-o", "ForkAfterAuthentication=no",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
            "--", host,
        ]
    }

    private static func isHostName(_ value: String) -> Bool {
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8
        return !value.isEmpty && !value.hasPrefix("-") && value.utf8.allSatisfy { allowed.contains($0) }
    }
}

struct PortForward: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var context: String?
    var namespace: String?
    var serviceName: String?
    var ssh: SSHForwardTarget?
    var localPort: Int
    var remotePort: Int
    var autoStart: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        context: String,
        namespace: String,
        serviceName: String,
        localPort: Int,
        remotePort: Int,
        autoStart: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.context = context
        self.namespace = namespace
        self.serviceName = serviceName
        self.localPort = localPort
        self.remotePort = remotePort
        self.autoStart = autoStart
        self.createdAt = createdAt
    }

    init(displayName: String, ssh: SSHForwardTarget, localPort: Int, remotePort: Int, autoStart: Bool = false) {
        self.id = UUID()
        self.displayName = displayName
        self.ssh = ssh
        self.localPort = localPort
        self.remotePort = remotePort
        self.autoStart = autoStart
        self.createdAt = Date()
    }

    var qualifiedTarget: String {
        if let ssh { return "\(ssh.host) → \(ssh.remoteHost):\(remotePort)" }
        return [context, namespace, serviceName].compactMap { $0 }.joined(separator: " / ")
    }

    var portMapping: String { "\(localPort) → \(remotePort)" }
}
