import Foundation

public enum MountFailureReason: Sendable, Equatable {
    case authenticationFailed
    case hostUnreachable
    case shareNotFound
    /// The mount system reported the mountpoint busy.
    case mountpointBusy
    /// The expected mountpoint is taken. Either the share was quietly given a
    /// different path because the expected one was occupied (spec §9.1), or the
    /// engine found the obstruction before mounting and refused to attempt. Distinct
    /// from `.mountpointBusy`: nothing refused us.
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
    /// What was in the way, when the failure is a blocked mountpoint and the engine
    /// worked out which kind. Optional so `MountFailure(reason:)` keeps compiling.
    public let obstruction: MountpointObstruction?
    /// The path `obstruction` describes. Carried alongside rather than inside the
    /// obstruction so the enum stays a description of a *kind* of problem.
    public let path: String?

    public init(
        reason: MountFailureReason,
        status: Int32? = nil,
        obstruction: MountpointObstruction? = nil,
        path: String? = nil
    ) {
        self.reason = reason
        self.status = status
        self.obstruction = obstruction
        self.path = path
    }

    /// What this particular failure tells the user to do.
    ///
    /// Prefers advice naming the real path over `reason.remedy`'s generic form. The
    /// reason-level remedy stays for callers that have a reason but no failure —
    /// `DiagnosticsReport` reads it statically.
    public var remedy: String? {
        guard let obstruction, let path else { return reason.remedy }
        switch obstruction {
        case .clear:
            return reason.remedy
        case .emptyDirectory:
            return """
                A leftover empty folder is sitting at \(path), which is why the share \
                mounted somewhere else. Remove it with: sudo rmdir \(path)
                """
        case .nonEmptyDirectory:
            return """
                \(path) already exists and has files in it, so the share cannot mount \
                there. Move or delete its contents first — it is not a mount, so \
                nothing will be ejected.
                """
        case .otherVolume(let from):
            return """
                \(from) is already mounted at \(path). Eject it, and the share will \
                mount there on the next attempt.
                """
        }
    }
}

public enum MountState: Sendable, Equatable {
    case idle
    case mounting
    case mounted(path: String)
    case stale(path: String)
    case failed(MountFailure)
}
