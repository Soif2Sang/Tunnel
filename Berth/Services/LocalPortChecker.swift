import Foundation

struct PortHolder: Equatable, Sendable {
    let pid: Int32
    let command: String?
}

/// Detects whether a local TCP port is already bound by another process,
/// and (optionally) terminates the holder.
struct LocalPortChecker: Sendable {
    func processUsing(port: Int) async -> Int32? {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let str = String(data: data, encoding: .utf8) ?? ""
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int32(trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? "") {
                    cont.resume(returning: pid)
                } else {
                    cont.resume(returning: nil)
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(returning: nil)
            }
        }
    }

    /// Returns information about the process currently holding `port`, if any.
    func holder(port: Int) async -> PortHolder? {
        guard let pid = await processUsing(port: port) else { return nil }
        let cmd = await commandName(for: pid)
        return PortHolder(pid: pid, command: cmd)
    }

    /// Sends SIGTERM (then SIGKILL after a short grace period) to whichever
    /// process is currently holding `port`. Returns true if the port is free
    /// when this method returns.
    func killHolder(port: Int) async -> Bool {
        guard let pid = await processUsing(port: port), pid > 0 else {
            return true // already free
        }
        kill(pid, SIGTERM)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if await processUsing(port: port) == nil { return true }
        }
        // Stubborn — escalate.
        kill(pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await processUsing(port: port) == nil
    }

    private func commandName(for pid: Int32) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-p", String(pid), "-o", "comm="]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let last = raw.split(separator: "/").last.map(String.init)
                cont.resume(returning: raw.isEmpty ? nil : (last ?? raw))
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
        }
    }
}
