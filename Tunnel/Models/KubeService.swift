import Foundation

struct KubeServicePort: Hashable, Sendable {
    var name: String?
    var port: Int
    var targetPort: String?
    var protocolName: String?
}

struct KubeService: Hashable, Identifiable, Sendable {
    var context: String
    var namespace: String
    var name: String
    var ports: [KubeServicePort]
    var labels: [String: String]

    var id: String { "\(context)/\(namespace)/\(name)" }

    var primaryPort: Int? { ports.first?.port }
    var qualifiedName: String { "\(context) / \(namespace) / \(name)" }
}
