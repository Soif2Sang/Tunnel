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
