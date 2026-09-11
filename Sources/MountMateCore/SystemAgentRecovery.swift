import Darwin
import Foundation
import Network

/// Asks whether the server accepts a TCP connection on its file-sharing port.
///
/// Answering here is what separates "the agent is stuck" from "the network is down":
/// the three wedges seen so far all had the NAS accepting connections on 445.
public struct TCPReachability: ServerReachability {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(3)) {
        self.timeout = timeout
    }

    public func answers(_ endpoint: ShareEndpoint) async -> Bool {
        guard let host = endpoint.url.host,
              let port = NWEndpoint.Port(rawValue: Self.port(for: endpoint)) else { return false }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let outcome = Once()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if outcome.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .waiting, .failed:
                    // `.waiting` is refused or unroutable: not answering.
                    if outcome.claim() { continuation.resume(returning: false) }
                    connection.cancel()
                case .cancelled:
                    if outcome.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            let seconds = Double(timeout.components.seconds)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                if outcome.claim() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }

    static func port(for endpoint: ShareEndpoint) -> UInt16 {
        if let explicit = endpoint.url.port, let port = UInt16(exactly: explicit) { return port }
        return endpoint.url.scheme?.lowercased() == "afp" ? 548 : 445
    }
}

/// Restarts this user's `NetAuthSysAgent`. launchd respawns it on demand.
///
/// `SIGTERM` first, then `SIGKILL` to the **same** processes if any survive the grace
/// period. Same processes, not the same name: launchd can respawn a fresh agent within
/// the grace period, and killing that one would be the bug this exists to fix. The
/// `SIGKILL` is not decoration — a stopped process, or one that ignores `SIGTERM`, would
/// otherwise survive and keep every mount queued behind it.
public struct NetAuthAgentResetter: AgentResetter {
    private let grace: Duration

    public init(grace: Duration = .seconds(2)) {
        self.grace = grace
    }

    public func restartNetworkMountAgent() async {
        let agents = await Self.agentProcessIDs()
        guard !agents.isEmpty else { return }

        for pid in agents { kill(pid, SIGTERM) }
        try? await Task.sleep(for: grace)
        // `kill(pid, 0)` asks whether it still exists without signalling it.
        for pid in agents where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// This user's agents only. Another user's cannot be signalled anyway, and asking
    /// by name alone would try.
    static func agentProcessIDs() async -> [pid_t] {
        let output = await run("/usr/bin/pgrep", ["-x", "-U", String(getuid()), "NetAuthSysAgent"])
        return output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }
}

/// Resumes a continuation exactly once across the threads that race to do it.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
