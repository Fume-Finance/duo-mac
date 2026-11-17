import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// A passkey kept in this iPhone's Secure Enclave, unlocked with Face ID (or the iPhone's passcode).
///
/// A web view inside an app can only use real passkeys with a paid Apple developer account, so the
/// app makes the same answers itself: the Mac checks them exactly as it checks a passkey's (Auth.swift):
/// client data with the challenge and the page's origin, authenticator data with the address's hash and
/// "user verified", and an ES256 signature over both. The private key never leaves the Secure Enclave,
/// and every signature needs Face ID.
enum Authenticator {
    enum Failure: Error {
        case cancelled, missing, failed
        /// The DOMException name the page expects.
        var name: String {
            switch self {
            case .cancelled, .missing: return "NotAllowedError"
            case .failed: return "UnknownError"
            }
        }
    }

    private static let tagPrefix = "com.riccardoconti.duomac.passkey."
    private static let queue = DispatchQueue(label: "duomac.passkey", qos: .userInitiated)

    /// Pairing: a new key. Face ID first, so it's set up (and allowed) right away.
    static func create(rpId: String, challenge: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let ctx = LAContext()
        ctx.localizedReason = "Unlock your Mac with Face ID"
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Set up Face ID for your Mac") { ok, _ in
            guard ok else { return completion(.failure(Failure.cancelled)) }
            queue.async {
                let credID = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64URL
                var error: Unmanaged<CFError>?
                var priv: [String: Any] = [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: Data((tagPrefix + credID).utf8),
                    kSecAttrLabel as String: "Duo Mac (\(rpId))",
                ]
                var attrs: [String: Any] = [
                    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeySizeInBits as String: 256,
                ]
                #if !targetEnvironment(simulator)
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                                   [.privateKeyUsage, .userPresence], &error) else {
                    return completion(.failure(Failure.failed))
                }
                priv[kSecAttrAccessControl as String] = access
                attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
                #endif
                attrs[kSecPrivateKeyAttrs as String] = priv
                guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
                      let pub = SecKeyCopyPublicKey(key),
                      let x963 = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
                    return completion(.failure(Failure.failed))
                }
                let clientData = clientDataJSON("webauthn.create", challenge: challenge, rpId: rpId)
                completion(.success([
                    "id": credID,
                    "clientData": clientData.base64URL,
                    "authData": authenticatorData(rpId: rpId).base64URL,
                    "pub": x963.dropFirst().base64URL, // x ‖ y
                    "fmt": "raw",
                ]))
            }
        }
    }

    /// Unlocking: sign the Mac's challenge (this is when Face ID shows).
    static func get(rpId: String, challenge: String, credentialID: String,
                    completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async {
            let ctx = LAContext()
            ctx.localizedReason = "Unlock your Mac"
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: Data((tagPrefix + credentialID).utf8),
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true,
                kSecUseAuthenticationContext as String: ctx,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let found = item,
                  CFGetTypeID(found) == SecKeyGetTypeID() else {
                return completion(.failure(Failure.missing))
            }
            let key = found as! SecKey
            let clientData = clientDataJSON("webauthn.get", challenge: challenge, rpId: rpId)
            let authData = authenticatorData(rpId: rpId)
            var signed = authData
            signed.append(contentsOf: SHA256.hash(data: clientData))
            var error: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, signed as CFData, &error) as Data? else {
                let code = (error?.takeRetainedValue() as Error?).map { ($0 as NSError).code } ?? 0
                let cancelled = code == Int(errSecUserCanceled) || code == LAError.userCancel.rawValue
                    || code == LAError.appCancel.rawValue || code == LAError.systemCancel.rawValue
                return completion(.failure(cancelled ? Failure.cancelled : Failure.failed))
            }
            completion(.success([
                "id": credentialID,
                "authData": authData.base64URL,
                "clientData": clientData.base64URL,
                "sig": sig.base64URL, // DER, as WebAuthn's ES256
            ]))
        }
    }

    private static func clientDataJSON(_ type: String, challenge: String, rpId: String) -> Data {
        let safe = challenge.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return Data(#"{"type":"\#(type)","challenge":"\#(safe)","origin":"https://\#(rpId)","crossOrigin":false}"#.utf8)
    }

    /// RP ID hash, flags (user present + user verified), counter 0 (like iCloud Keychain passkeys).
    private static func authenticatorData(rpId: String) -> Data {
        var d = Data(SHA256.hash(data: Data(rpId.utf8)))
        d.append(contentsOf: [0x05, 0, 0, 0, 0])
        return d
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
