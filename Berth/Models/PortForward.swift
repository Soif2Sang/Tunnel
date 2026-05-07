import Foundation

struct PortForward: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var context: String
    var namespace: String
    var serviceName: String
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

    var qualifiedTarget: String { "\(context) / \(namespace) / \(serviceName)" }
    var portMapping: String { ":\(localPort) → \(remotePort)" }
}
