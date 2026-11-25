import Foundation

enum GCloudAuthLoginLauncher {
    /// gcloud owns the browser OAuth callback; its exit status is the completion signal.
    /// No shell, Terminal automation, or manual confirmation is needed.
    static func runLogin(extraPath: String, timeout: TimeInterval = 300) async throws {
        var environment = ProcessInfo.processInfo.environment
        let searchPath = [extraPath, environment["PATH"] ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        let gcloudPath = searchPath
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("gcloud").path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })

        guard let gcloudPath else {
            throw GCloudAuthLoginError.gcloudNotFound
        }

        environment["PATH"] = searchPath
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gcloudPath)
        process.arguments = ["auth", "login", "--brief", "--quiet", "--launch-browser"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // Drain both streams together while gcloud runs, including verbose failures.
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try Task.checkCancellation()
        try process.run()
        let outputTask = Task.detached {
            outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer { try? outputPipe.fileHandleForReading.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw GCloudAuthLoginError.timedOut
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                // No interactive shell to clean up: kill the owned login process on cancellation.
                kill(process.processIdentifier, SIGKILL)
            }
            _ = await outputTask.value
            throw error
        }
        let output = await outputTask.value
        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GCloudAuthLoginError.loginFailed(process.terminationStatus, message)
        }
    }
}

enum GCloudAuthLoginError: Error, LocalizedError {
    case gcloudNotFound
    case timedOut
    case loginFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .gcloudNotFound:
            return "gcloud was not found on the app's PATH"
        case .timedOut:
            return "Google Cloud login timed out. Please try again and complete sign-in in your browser."
        case .loginFailed(let status, let message):
            return message.isEmpty ? "gcloud auth login exited with status \(status)" : message
        }
    }
}
