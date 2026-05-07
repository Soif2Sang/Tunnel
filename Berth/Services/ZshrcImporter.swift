import Foundation

struct ImportedAlias: Identifiable, Hashable {
    let id = UUID()
    var aliasName: String
    var rawCommand: String
    var parsed: PortForward?
    var note: String?
}

struct ZshrcImporter {
    /// Reads ~/.zshrc and returns one ImportedAlias per `alias pf-* = ...` line.
    /// `defaultContext` is used because aliases don't typically include `--context`.
    static func importFromZshrc(path: String? = nil, defaultContext: String) -> [ImportedAlias] {
        let zshrc = path ?? (NSHomeDirectory() as NSString).appendingPathComponent(".zshrc")
        guard let contents = try? String(contentsOfFile: zshrc, encoding: .utf8) else {
            return []
        }
        var results: [ImportedAlias] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            guard let parsed = parseLine(String(trimmed), defaultContext: defaultContext) else { continue }
            results.append(parsed)
        }
        return results
    }

    /// Returns nil if the line doesn't look like a port-forward alias.
    static func parseLine(_ line: String, defaultContext: String) -> ImportedAlias? {
        // Forms we accept:
        //   alias pf-foo="kubectl port-forward services/<svc> <local>:<remote> -n <ns>"
        //   alias pf-foo='kubectl port-forward services/<svc> <local>:<remote> -n <ns>'
        // Tolerate either order of `services/X` and `-n N`, and either quote style.
        guard line.hasPrefix("alias ") else { return nil }
        let afterAlias = String(line.dropFirst("alias ".count))
        guard let eq = afterAlias.firstIndex(of: "=") else { return nil }
        let name = String(afterAlias[..<eq]).trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix("pf-") else { return nil }
        var rhs = String(afterAlias[afterAlias.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        // Strip outer quotes
        if (rhs.hasPrefix("\"") && rhs.hasSuffix("\"")) || (rhs.hasPrefix("'") && rhs.hasSuffix("'")) {
            rhs = String(rhs.dropFirst().dropLast())
        }
        // Must reference kubectl port-forward
        guard rhs.contains("kubectl") && rhs.contains("port-forward") else {
            return ImportedAlias(aliasName: name, rawCommand: rhs, parsed: nil, note: "Not a kubectl port-forward command")
        }

        // Find services/<svc>
        let serviceRegex = try? NSRegularExpression(pattern: #"services/([A-Za-z0-9._-]+)"#)
        let nsRange = NSRange(rhs.startIndex..., in: rhs)
        guard let svcMatch = serviceRegex?.firstMatch(in: rhs, range: nsRange),
              let svcRange = Range(svcMatch.range(at: 1), in: rhs)
        else {
            return ImportedAlias(aliasName: name, rawCommand: rhs, parsed: nil, note: "Couldn't find services/<name>; manual setup required")
        }
        let serviceName = String(rhs[svcRange])

        // Find local:remote (digits:digits)
        let portRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z])(\d{2,5}):(\d{2,5})"#)
        guard let portMatch = portRegex?.firstMatch(in: rhs, range: nsRange),
              let lr = Range(portMatch.range(at: 1), in: rhs),
              let rr = Range(portMatch.range(at: 2), in: rhs),
              let lp = Int(rhs[lr]),
              let rp = Int(rhs[rr])
        else {
            return ImportedAlias(aliasName: name, rawCommand: rhs, parsed: nil, note: "Couldn't extract local:remote ports")
        }

        // Find -n <namespace>
        let nsRegex = try? NSRegularExpression(pattern: #"-n\s+([A-Za-z0-9._-]+)"#)
        guard let nsMatch = nsRegex?.firstMatch(in: rhs, range: nsRange),
              let nr = Range(nsMatch.range(at: 1), in: rhs)
        else {
            return ImportedAlias(aliasName: name, rawCommand: rhs, parsed: nil, note: "Couldn't extract namespace (-n)")
        }
        let namespace = String(rhs[nr])

        // Reject lines containing `$(` (subshells, like the adsleuth one) — we don't trust the parsed
        // service since the alias used a pod-grep dance instead.
        if rhs.contains("$(") {
            return ImportedAlias(aliasName: name, rawCommand: rhs, parsed: nil, note: "Uses shell substitution; please re-create as a service forward")
        }

        let pf = PortForward(
            displayName: name.replacingOccurrences(of: "pf-", with: ""),
            context: defaultContext,
            namespace: namespace,
            serviceName: serviceName,
            localPort: lp,
            remotePort: rp,
            autoStart: false
        )
        return ImportedAlias(aliasName: name, rawCommand: rhs, parsed: pf, note: nil)
    }
}
