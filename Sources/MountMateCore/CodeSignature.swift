import Foundation
import Security

/// What the running process is signed with.
public enum CodeSignature {
    /// The team identifier in this process's signature, or nil when it has none —
    /// ad-hoc, self-signed and unsigned code all report nil.
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }

        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
