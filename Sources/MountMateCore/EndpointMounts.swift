import Foundation

/// Which of the mount table's entries belong to one endpoint, and which of those are
/// in the wrong place.
///
/// A stray `<name>-1` mount carries the **same** `f_mntfromname` as the real share —
/// only the mountpoint differs — which is what makes `from` a precise ownership test
/// and what made `MountEngine`'s old `.first` lookup adopt a stray as the real thing.
///
/// Pure and synchronous, like `ExpectedMountpoint` and `BackoffPolicy`, so the policy
/// is testable without a mount table.
public enum EndpointMounts {
    public struct Partition: Equatable, Sendable {
        /// The mount at `ExpectedMountpoint.path(for:)`, if the endpoint has one.
        public let expected: MountedVolume?
        /// Mounts of this endpoint's share that landed anywhere else.
        public let strays: [MountedVolume]
    }

    public static func partition(
        _ volumes: [MountedVolume], for endpoint: ShareEndpoint
    ) -> Partition {
        let identifier = endpoint.mountFromIdentifier
        // A mount of a *different* share at our expected path has a different `from`
        // and is deliberately not ours: it is an obstruction, and unmounting it would
        // be tearing down somebody else's volume.
        let mine = volumes.filter { $0.from == identifier }
        return Partition(
            expected: mine.first { ExpectedMountpoint.matches($0.on, for: endpoint) },
            strays: mine.filter { !ExpectedMountpoint.matches($0.on, for: endpoint) }
        )
    }
}
