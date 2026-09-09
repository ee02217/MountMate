import Foundation

public enum MountFailureReason: Sendable, Equatable {
    case authenticationFailed
    case hostUnreachable
    case shareNotFound
    case mountpointBusy
    case timedOut
    case noCredential
    case unknown
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
