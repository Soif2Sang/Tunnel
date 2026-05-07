import Foundation

actor KubeContextLoader {
    private let client: KubectlClient

    init(client: KubectlClient = .shared) {
        self.client = client
    }

    /// Returns all contexts from `~/.kube/config`, marking the current one.
    func loadContexts() async throws -> [KubeContext] {
        async let contextsText = client.runText(["config", "get-contexts", "-o", "name"])
        async let currentText = client.runText(["config", "current-context"])

        let names = try await contextsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let current = (try? await currentText)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return names.map { KubeContext(name: $0, cluster: nil, namespace: nil, isCurrent: $0 == current) }
    }
}
