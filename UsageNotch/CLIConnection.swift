import Darwin
import Foundation
import os

/// A short-lived, bounded JSON exchange with a locally installed CLI.
struct CLIConnection {
    private let input: FileHandle
    private let output: FileHandle
    private let deadline: ContinuousClock.Instant
    private var buffered = Data()
    private static let responseLimit = 2 * 1024 * 1024
    private static let children = OSAllocatedUnfairLock(initialState: Children())

    private struct Children {
        var stopping = false
        var active: [ObjectIdentifier: Process] = [:]
    }

    static func stopAll() {
        let active = children.withLock { state in
            state.stopping = true
            return Array(state.active.values)
        }
        for child in active where child.isRunning {
            child.terminate()
        }
        let cutoff = ContinuousClock.now + .milliseconds(250)
        while active.contains(where: \.isRunning) && ContinuousClock.now < cutoff {
            Thread.sleep(forTimeInterval: 0.025)
        }
        for child in active where child.isRunning {
            _ = kill(child.processIdentifier, SIGKILL)
        }
    }

    static func run<T>(
        _ provider: Provider, arguments: [String], exchange: (inout CLIConnection) throws -> T
    ) throws -> T {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        let searchPaths = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin"
        ] + (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
          + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        guard let executable = searchPaths.lazy.map({ "\($0)/\(provider.command)" })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw UsageFailure.commandMissing
        }
        environment["PATH"] = searchPaths.joined(separator: ":")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UsageNotch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stdin = Pipe()
        let stdout = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw UsageFailure.unavailable }
        let id = ObjectIdentifier(process)
        try children.withLock { state in
            guard !state.stopping else { throw UsageFailure.unavailable }
            try process.run()
            state.active[id] = process
        }
        defer {
            try? input.close()
            try? output.close()
            if process.isRunning {
                process.terminate()
                let cutoff = ContinuousClock.now + .milliseconds(250)
                while process.isRunning && ContinuousClock.now < cutoff {
                    Thread.sleep(forTimeInterval: 0.025)
                }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            _ = children.withLock { $0.active.removeValue(forKey: id) }
        }

        var cli = Self(input: input, output: output, deadline: .now + .seconds(25))
        return try exchange(&cli)
    }

    func send(_ line: String) throws {
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    mutating func receive<T: Decodable>(matching match: ([String: Any]) -> Bool) throws -> T {
        while true {
            while let newline = buffered.firstIndex(of: 10) {
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                if let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], match(value) {
                    return try JSONDecoder().decode(T.self, from: line)
                }
            }
            guard try appendOutput() else { throw UsageFailure.unavailable }
        }
    }

    mutating func readDocument<T: Decodable>() throws -> T {
        while try appendOutput() {}
        return try JSONDecoder().decode(T.self, from: buffered)
    }

    private mutating func appendOutput() throws -> Bool {
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let millis = max(1, remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000)
            var fd = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, Int32(millis))
            if ready == 0 || (ready == -1 && errno == EINTR) { continue }
            guard ready > 0 else { throw UsageFailure.unavailable }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count == -1 && errno == EINTR { continue }
            guard count >= 0 else { throw UsageFailure.unavailable }
            guard count > 0 else { return false }
            buffered.append(contentsOf: bytes.prefix(count))
            guard buffered.count <= Self.responseLimit else { throw UsageFailure.unavailable }
            return true
        }
        throw UsageFailure.timedOut
    }
}
