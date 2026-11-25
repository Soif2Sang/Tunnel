import Foundation

actor ConfigStore {
    struct File: Codable {
        var version: Int
        var forwards: [PortForward]
    }

    private let url: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.url = fileURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Tunnel", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.url = dir.appendingPathComponent("forwards.json")
        }
    }

    func load() throws -> [PortForward] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: data)
        try Self.validate(file.forwards)
        return file.forwards
    }

    struct ValidationError: Error, CustomStringConvertible {
        let description: String
    }

    static func validate(_ forwards: [PortForward]) throws {
        var seen = Set<UUID>()
        for f in forwards {
            let label = f.displayName.isEmpty ? f.id.uuidString : f.displayName
            guard seen.insert(f.id).inserted else {
                throw ValidationError(description: "Duplicate id \(f.id.uuidString)")
            }
            if let ssh = f.ssh {
                guard ssh.isValid, f.context == nil, f.namespace == nil, f.serviceName == nil else {
                    throw ValidationError(description: "\(label): invalid or mixed SSH target")
                }
            } else if f.context?.isEmpty != false || f.namespace?.isEmpty != false || f.serviceName?.isEmpty != false {
                throw ValidationError(description: "\(label): context, namespace and serviceName are required")
            }
            guard (1024...65535).contains(f.localPort) else {
                throw ValidationError(description: "\(label): local port must be 1024–65535")
            }
            guard (1...65535).contains(f.remotePort) else {
                throw ValidationError(description: "\(label): remote port must be 1–65535")
            }
        }
    }

    func save(_ forwards: [PortForward]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let file = File(version: 1, forwards: forwards)
        let data = try encoder.encode(file)
        // Atomic write
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    var fileURL: URL { url }
}
