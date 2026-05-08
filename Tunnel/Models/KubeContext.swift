import Foundation

struct KubeContext: Hashable, Identifiable, Sendable {
    var name: String
    var cluster: String?
    var namespace: String?
    var isCurrent: Bool

    var id: String { name }
}
