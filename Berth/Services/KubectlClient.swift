import Foundation

enum KubectlError: Error, Equatable {
    case notFound
    case nonZeroExit(code: Int32, stderr: String)
    case decodingFailed(String)
    case timeout
}

enum KubectlEvent: Sendable {
    case stdoutLine(String)
    case stderrLine(String)
    case terminated(status: Int32)
}

actor KubectlClient {
    static let shared = KubectlClient()

    private(set) var executablePath: String
    private(set) var extraPath: String

    init(
        executablePath: String? = nil,
        extraPath: String? = nil
    ) {
        self.executablePath = executablePath ?? KubectlClient.detectKubectlPath()
        self.extraPath = extraPath ?? KubectlClient.defaultExtraPath()
    }

    static func defaultExtraPath() -> String {
        // Krew installs kubectl plugins (e.g. oidc-login) under ~/.krew/bin.
        // Include it before the standard prefixes so `kubectl <plugin>` resolves.
        let home = NSHomeDirectory()
        return "\(home)/.krew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    }

    func setExecutablePath(_ path: String) { self.executablePath = path }
    func setExtraPath(_ path: String) { self.extraPath = path }

    static func detectKubectlPath() -> String {
        let candidates = ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl", "/usr/bin/kubectl"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/local/bin/kubectl"
    }

    private func makeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = extraPath
        // Required for kubectl to find ~/.kube/config & oidc-login cache
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        return env
    }

    /// Run kubectl one-shot, decoding stdout JSON into `T`. Throws on non-zero exit.
    func runJSON<T: Decodable>(_ args: [String], timeout: TimeInterval = 15, as type: T.Type = T.self) async throws -> T {
        let result = try await runOnce(args: args, timeout: timeout)
        guard result.terminationStatus == 0 else {
            throw KubectlError.nonZeroExit(code: result.terminationStatus, stderr: result.stderr)
        }
        do {
            return try JSONDecoder().decode(T.self, from: result.stdoutData)
        } catch {
            throw KubectlError.decodingFailed("\(error)")
        }
    }

    /// Run kubectl one-shot, returning raw stdout text (e.g. for `config get-contexts -o name`).
    func runText(_ args: [String], timeout: TimeInterval = 10) async throws -> String {
        let result = try await runOnce(args: args, timeout: timeout)
        guard result.terminationStatus == 0 else {
            throw KubectlError.nonZeroExit(code: result.terminationStatus, stderr: result.stderr)
        }
        return String(data: result.stdoutData, encoding: .utf8) ?? ""
    }

    struct OneShotResult: Sendable {
        var terminationStatus: Int32
        var stdoutData: Data
        var stderr: String
    }

    private func runOnce(args: [String], timeout: TimeInterval) async throws -> OneShotResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw KubectlError.notFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.environment = makeEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = DataBuffer()
        let stderrBuffer = DataBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { await stdoutBuffer.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { await stderrBuffer.append(data) }
        }

        try process.run()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OneShotResult, Error>) in
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning {
                        process.terminate()
                    }
                }
                process.terminationHandler = { proc in
                    timeoutTask.cancel()
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    Task {
                        let stdoutData = await stdoutBuffer.data()
                        let stderrData = await stderrBuffer.data()
                        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                        cont.resume(returning: OneShotResult(
                            terminationStatus: proc.terminationStatus,
                            stdoutData: stdoutData,
                            stderr: stderrString
                        ))
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Spawn a long-running kubectl invocation, streaming stdout/stderr lines and termination.
    /// Returns (process, stream). Caller must keep `process` to terminate the child.
    func streaming(_ args: [String]) throws -> (Process, AsyncStream<KubectlEvent>) {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw KubectlError.notFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.environment = makeEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stream = AsyncStream<KubectlEvent> { (continuation: AsyncStream<KubectlEvent>.Continuation) in
            let stdoutAccum = LineAccumulator { line in continuation.yield(.stdoutLine(line)) }
            let stderrAccum = LineAccumulator { line in continuation.yield(.stderrLine(line)) }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    stdoutAccum.flush()
                    return
                }
                stdoutAccum.feed(data)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    stderrAccum.flush()
                    return
                }
                stderrAccum.feed(data)
            }

            process.terminationHandler = { proc in
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                stdoutAccum.flush()
                stderrAccum.flush()
                continuation.yield(.terminated(status: proc.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                if process.isRunning { process.terminate() }
            }
        }

        try process.run()
        return (process, stream)
    }
}

/// Thread-safe Data accumulator for one-shot stdout/stderr collection.
private actor DataBuffer {
    private var buf = Data()
    func append(_ data: Data) { buf.append(data) }
    func data() -> Data { buf }
}

/// Buffer bytes and emit complete lines (split on `\n`) via the callback.
/// Not actor-isolated because Pipe.readabilityHandler is sync.
final class LineAccumulator: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: 0..<nl)
            buffer.removeSubrange(0...nl)
            if let s = String(data: lineData, encoding: .utf8) {
                lines.append(s)
            }
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    func flush() {
        lock.lock()
        let remaining = buffer
        buffer.removeAll()
        lock.unlock()
        if !remaining.isEmpty, let s = String(data: remaining, encoding: .utf8), !s.isEmpty {
            onLine(s)
        }
    }
}
