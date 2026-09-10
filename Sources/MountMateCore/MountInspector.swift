import Foundation

public struct MountedVolume: Sendable, Equatable {
    /// `f_mntfromname`, e.g. `//smbshare@192.168.1.67/Multimedia`.
    public let from: String
    /// `f_mntonname`, e.g. `/Volumes/Multimedia`.
    public let on: String

    public init(from: String, on: String) {
        self.from = from
        self.on = on
    }
}

public protocol MountInspector: Sendable {
    func mountedVolumes() async -> [MountedVolume]
    /// Whether the mount at `path` actually answers. A mount can be listed but dead.
    func isResponsive(path: String) async -> Bool
}
