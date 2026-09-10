import Testing
import Foundation
import NetFS
@testable import MountMateCore

@Test func openOptionsAlwaysSuppressUI() {
    let options = NetFSMountService.makeOpenOptions()
    #expect(options[kNAUIOptionKey] as? String == (kNAUIOptionNoUI as String))
}

@Test func volumesPolicyNeverPinsTheMountpoint() {
    // Regression: pre-creating /Volumes/<name> makes NetFS mount at <name>-1 instead,
    // which is invisible to anything pointed at <name>. Never pin under .volumes.
    let options = NetFSMountService.makeMountOptions(policy: .volumes, readOnly: false)
    #expect(options[kNetFSMountAtMountDirKey] == nil)
}

@Test func customPolicyPinsTheMountpoint() {
    let options = NetFSMountService.makeMountOptions(
        policy: .custom(path: "/Users/me/mnt/media"), readOnly: false
    )
    #expect(options[kNetFSMountAtMountDirKey] as? Bool == true)
}

@Test func mountOptionsAlwaysRequestSoftFailure() {
    // A hard mount to a dead server hangs I/O forever; soft mounts return errors.
    for policy in [MountPolicy.volumes, .custom(path: "/tmp/x")] {
        let options = NetFSMountService.makeMountOptions(policy: policy, readOnly: false)
        #expect(options[kNetFSSoftMountKey] as? Bool == true)
    }
}
