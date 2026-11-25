import XCTest
@testable import Tunnel

final class ConfigStoreTests: XCTestCase {
    private func makeForward(id: UUID = UUID(), local: Int = 3100, remote: Int = 3000) -> PortForward {
        PortForward(
            id: id, displayName: "api", context: "ctx", namespace: "ns",
            serviceName: "svc", localPort: local, remotePort: remote
        )
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-\(UUID().uuidString).json")
    }

    func testRoundTrip() async throws {
        let store = ConfigStore(fileURL: tempURL())
        let forwards = [makeForward(), makeForward(local: 3200)]
        try await store.save(forwards)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.map(\.id), forwards.map(\.id))
    }

    func testRejectsDuplicateIDs() {
        let id = UUID()
        XCTAssertThrowsError(try ConfigStore.validate([makeForward(id: id), makeForward(id: id, local: 3200)]))
    }

    func testRejectsPrivilegedLocalPort() {
        XCTAssertThrowsError(try ConfigStore.validate([makeForward(local: 80)]))
    }

    func testRejectsInvalidRemotePort() {
        XCTAssertThrowsError(try ConfigStore.validate([makeForward(remote: 0)]))
    }

    func testLoadsLegacyKubernetesAndRoundTripsMixedConfig() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"version":1,"forwards":[{"id":"C9FFC49A-78B0-4769-945C-99AC963925CA",
        "displayName":"API","context":"ctx","namespace":"ns","serviceName":"api",
        "localPort":3100,"remotePort":3000,"autoStart":true,"createdAt":"2026-01-01T00:00:00Z"}]}
        """
        try Data(legacy.utf8).write(to: url)
        let store = ConfigStore(fileURL: url)
        let kubernetes = try await store.load()
        XCTAssertEqual(kubernetes.first?.context, "ctx")
        XCTAssertEqual(kubernetes.first?.autoStart, true)
        XCTAssertNil(kubernetes.first?.ssh)

        let ssh = PortForward(displayName: "VPS", ssh: SSHForwardTarget(host: "vps", remoteHost: "127.0.0.1"),
                              localPort: 8787, remotePort: 8787, autoStart: true)
        try await store.save(kubernetes + [ssh])
        let mixed = try await store.load()
        XCTAssertEqual(mixed.first, kubernetes.first)
        XCTAssertEqual(mixed.last?.ssh, ssh.ssh)
        XCTAssertEqual(mixed.last?.autoStart, true)
        XCTAssertNil(mixed.last?.context)
    }

    func testSSHArgumentsKeepTheListenerOnIPv4Loopback() {
        let target = SSHForwardTarget(host: "vps", remoteHost: "127.0.0.1")
        XCTAssertEqual(target.arguments(localPort: 8787, remotePort: 8787), [
            "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ControlPath=none",
            "-o", "ForkAfterAuthentication=no", "-L", "127.0.0.1:8787:127.0.0.1:8787", "--", "vps",
        ])
    }

    func testRejectsMalformedAndMixedSSHTargets() {
        for (host, destination) in [("-F", "localhost"), ("vps", "localhost:123"), ("ssh vps", "localhost")] {
            let target = SSHForwardTarget(host: host, remoteHost: destination)
            let forward = PortForward(displayName: "VPS", ssh: target, localPort: 8787, remotePort: 8787)
            XCTAssertThrowsError(try ConfigStore.validate([forward]))
        }
        var mixed = makeForward()
        mixed.ssh = SSHForwardTarget(host: "vps", remoteHost: "localhost")
        XCTAssertThrowsError(try ConfigStore.validate([mixed]))
    }

    func testSSHExitDistinguishesAuthenticationBindFailureAndDisconnect() {
        let auth = PortForwardSession.sshExitState(status: 255, localPort: 8787, logs: ["Permission denied (publickey)."])
        XCTAssertEqual(auth, .failed(reason: .other("Permission denied (publickey). Check this host in Terminal.")))
        let bind = PortForwardSession.sshExitState(status: 255, localPort: 8787, logs: ["bind: Address already in use"])
        XCTAssertEqual(bind, .failed(reason: .localPortInUse(8787)))
        let network = PortForwardSession.sshExitState(status: 255, localPort: 8787, logs: ["Connection reset by peer"])
        guard case .reconnecting(_, _, let lastError) = network else { return XCTFail("Expected retry") }
        XCTAssertEqual(lastError, "Connection reset by peer")
    }

    func testLoadFailsOnInvalidFile() async throws {
        let url = tempURL()
        try Data(#"{"version":1,"forwards":[{"bad":true}]}"#.utf8).write(to: url)
        let store = ConfigStore(fileURL: url)
        do {
            _ = try await store.load()
            XCTFail("Expected load to throw")
        } catch {}
    }
}
