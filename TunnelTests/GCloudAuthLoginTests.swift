import XCTest
@testable import Tunnel

@MainActor
final class GCloudAuthLoginTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tunnel login tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeExecutable(_ name: String, in directory: URL, script: String) throws {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testLoginRunsDirectlyWithBrowserAndNoInteractiveInput() async throws {
        let directory = try makeDirectory()
        try writeExecutable("gcloud", in: directory, script: """
        [ "$*" = "auth login --brief --quiet --launch-browser" ] || exit 2
        if read -r input; then exit 3; fi
        exit 0
        """)
        try await GCloudAuthLoginLauncher.runLogin(extraPath: directory.path)
    }

    func testLoginReportsFailureAndDrainsLargeOutput() async throws {
        let directory = try makeDirectory()
        try writeExecutable("gcloud", in: directory, script: """
        /usr/bin/head -c 100000 /dev/zero
        echo "Browser authentication rejected" >&2
        exit 7
        """)
        do {
            try await GCloudAuthLoginLauncher.runLogin(extraPath: directory.path)
            XCTFail("Expected login failure")
        } catch GCloudAuthLoginError.loginFailed(let status, let message) {
            XCTAssertEqual(status, 7)
            XCTAssertTrue(message.contains("Browser authentication rejected"))
        }
    }

    func testLoginTimesOut() async throws {
        let directory = try makeDirectory()
        try writeExecutable("gcloud", in: directory, script: "exec /bin/sleep 30")
        do {
            try await GCloudAuthLoginLauncher.runLogin(extraPath: directory.path, timeout: 0.2)
            XCTFail("Expected timeout")
        } catch GCloudAuthLoginError.timedOut {
            // The owned subprocess is terminated, not left waiting for a browser callback.
        }
    }

    func testLoginCanBeCancelled() async throws {
        let directory = try makeDirectory()
        try writeExecutable("gcloud", in: directory, script: "exec /bin/sleep 30")
        let login = Task { try await GCloudAuthLoginLauncher.runLogin(extraPath: directory.path) }
        try await Task.sleep(for: .milliseconds(200))
        login.cancel()
        do {
            try await login.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testManagerAutomaticallyRestartsForwardsAfterOneSharedLogin() async throws {
        let directory = try makeDirectory()
        // All mock state stays next to the executable, including paths containing spaces.
        try writeExecutable("gcloud", in: directory, script: """
        cd "$(dirname "$0")"
        echo login >> logins
        /bin/sleep 1
        touch authenticated
        """)
        try writeExecutable("kubectl", in: directory, script: """
        cd "$(dirname "$0")"
        if [ ! -f authenticated ]; then
            echo 'gke-gcloud-auth-plugin: cannot prompt during non-interactive execution' >&2
            /bin/sleep 0.2
            exit 1
        fi
        echo 'Forwarding from 127.0.0.1:48123 -> 3000'
        exec /bin/sleep 30
        """)
        let client = KubectlClient(
            executablePath: directory.appendingPathComponent("kubectl").path,
            extraPath: directory.path + ":/usr/bin:/bin"
        )
        let manager = PortForwardManager(client: client)
        let forwards = [48123, 48124].map {
            PortForward(displayName: "Test \($0)", context: "test", namespace: "test",
                        serviceName: "test", localPort: $0, remotePort: 3000)
        }
        for forward in forwards { await manager.start(forward: forward) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var allRunning = false
        while ContinuousClock.now < deadline {
            var runningCount = 0
            for forward in forwards {
                if case .running = await manager.currentState(for: forward.id) { runningCount += 1 }
            }
            if runningCount == forwards.count {
                allRunning = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await manager.shutdown()
        XCTAssertTrue(allRunning, "Forwards should reconnect without a manual click")
        let logins = try String(contentsOf: directory.appendingPathComponent("logins"), encoding: .utf8)
        XCTAssertEqual(logins, "login\n", "Concurrent failures should share one browser login")
    }
}
