import Foundation
import CryptoKit

struct UserAccount: Codable, Equatable {
    var name: String
    var email: String
    var createdAt = Date()
}

/// Local-only credential handling: a salted SHA-256 digest kept in the Keychain.
/// There is no server; registration is the gate that personalizes the app.
enum Credentials {
    struct Stored: Codable {
        var salt: Data
        var digest: Data
    }

    static func register(email: String, password: String) throws {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
            throw KeychainStore.KeychainError.unexpectedStatus(errSecInternalComponent)
        }
        let salt = Data(saltBytes)
        let stored = Stored(salt: salt, digest: digest(password: password, salt: salt))
        try KeychainStore.save(JSONEncoder().encode(stored), account: email)
    }

    static func verify(email: String, password: String) -> Bool {
        guard let data = try? KeychainStore.load(account: email),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        return digest(password: password, salt: stored.salt) == stored.digest
    }

    static func remove(email: String) {
        try? KeychainStore.delete(account: email)
    }

    private static func digest(password: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(password.utf8)))
    }
}
