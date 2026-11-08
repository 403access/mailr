import CryptoKit
import Foundation

/// Deterministic UUIDs used for accounts that are defined outside the normal
/// Add Account flow. Re-importing the same source updates the same account
/// instead of creating duplicates.
public enum StableAccountID {
    public static func email(_ email: String) -> UUID {
        make("mailr-account:\(email.lowercased())")
    }

    public static func localProfile(path: String) -> UUID {
        make("mailr-local-profile:\(path)")
    }

    public static func make(_ seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))

        // RFC 4122 version 4 / variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }
}
