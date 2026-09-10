import Foundation

public enum MountFailureReason: Sendable, Equatable {
    case authenticationFailed
    case hostUnreachable
    case shareNotFound
    /// The mount system reported the mountpoint busy.
    case mountpointBusy
    /// The share mounted somewhere other than where it belongs, because the expected
    /// mountpoint was taken. Distinct from `.mountpointBusy`: nothing refused us, we
    /// were quietly given a different path (spec §9.1).
    case mountpointOccupied
    case timedOut
    /// The server has taken every slot in its `BlockingCallBudget`: earlier mount
    /// calls against it are still parked in the kernel and have never returned, so
    /// this attempt was refused rather than stranding another thread. Distinct from
    /// `.hostUnreachable`, where the network answered "no" — here nothing answered at
    /// all, and distinct from `.timedOut`, where we did spend a thread waiting.
    case serverNotResponding
    case noCredential
    case unknown
}

extension MountFailureReason {
    /// What a person can actually do about it, where there is something.
    ///
    /// Most failures have no useful remedy — "the server could not be reached" is not
    /// improved by advice. This one does, and it is not guessable: the app is given a
    /// different path without being told why, and the cause is a directory or a disk
    /// nobody was looking at.
    public var remedy: String? {
        switch self {
        case .mountpointOccupied:
            return """
                Something else is using that folder in /Volumes. Eject any disk with \
                the same name, or remove a leftover folder with: \
                sudo rmdir /Volumes/<share name>
                """
        case .serverNotResponding:
            return """
                The server accepted the connection but never answered, and earlier \
                attempts are still waiting on it. Trying again cannot succeed while \
                it is in that state, so MountMate has stopped until it clears. \
                Restart file sharing on the server, or restart this Mac; mounting \
                resumes on its own.
                """
        case .authenticationFailed, .hostUnreachable, .shareNotFound,
             .mountpointBusy, .timedOut, .noCredential, .unknown:
            return nil
        }
    }
}

public struct MountFailure: Sendable, Equatable, Error {
    public let reason: MountFailureReason
    public let status: Int32?

    public init(reason: MountFailureReason, status: Int32? = nil) {
        self.reason = reason
        self.status = status
    }
}

public enum MountState: Sendable, Equatable {
    case idle
    case mounting
    case mounted(path: String)
    case stale(path: String)
    case failed(MountFailure)
}
