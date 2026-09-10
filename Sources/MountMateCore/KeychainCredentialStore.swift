import Foundation
import Security

/// Builds the attribute dictionary identifying one endpoint's Keychain item.
///
/// Keyed on server + account + protocol + path, which is the shape macOS itself uses
/// for network shares (spec §5.6) — so the items read sensibly in Keychain Access
/// rather than appearing as opaque blobs. Pure, so the keying rule is testable
/// without a Keychain, which matters because the Keychain is unreachable from any
/// process outside the user's GUI session.
enum KeychainQuery {
    static func attributes(for endpoint: ShareEndpoint) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword as String,
            kSecAttrServer as String: endpoint.url.host ?? "",
            kSecAttrAccount as String: endpoint.username,
            kSecAttrPath as String: endpoint.url.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            kSecAttrProtocol as String: protocolAttribute(for: endpoint) as String,
        ]
    }

    private static func protocolAttribute(for endpoint: ShareEndpoint) -> CFString {
        // `ShareEndpoint` refuses every scheme but these two, so the default is
        // unreachable today; it exists so adding a scheme there fails loudly here
        // rather than silently filing items under the wrong protocol.
        switch endpoint.url.scheme?.lowercased() {
        case "afp": return kSecAttrProtocolAFP
        default: return kSecAttrProtocolSMB
        }
    }
}
