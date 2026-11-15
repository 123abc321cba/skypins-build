import CryptoKit
import Foundation
import Security

/// ECDH P-256 + HKDF-SHA256 + AES-256-GCM
/// 与 PC 端 crypto.py (cryptography.hazmat) 对等
final class CryptoBox {
    private let privateKey: P256.KeyAgreement.PrivateKey
    private var sharedSecret: SharedSecret?
    private var symmetricKey: SymmetricKey?
    private var sendNonce: UInt64 = 0
    private var recvNonce: UInt64 = 0

    init() {
        privateKey = P256.KeyAgreement.PrivateKey()
    }

    /// SEC1 X9.62 未压缩点: 04 || X(32) || Y(32) —— 65 字节
    var publicKeyBytes: Data {
        privateKey.publicKey.x963Representation
    }

    var publicKeyBase64: String {
        publicKeyBytes.base64EncodedString()
    }

    var publicKeyHex: String {
        publicKeyBytes.map { String(format: "%02x", $0) }.joined()
    }

    var fingerprint: String {
        SHA256.hash(data: publicKeyBytes).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 用对端公钥推导共享密钥 (HKDF-SHA256, salt/info 与 PC 端一致)
    func derive(peerPubkeyBase64: String) throws {
        guard let peerData = Data(base64Encoded: peerPubkeyBase64),
              peerData.count == 65,
              peerData[0] == 0x04 else {
            throw CryptoError.invalidPublicKey
        }
        let peerPubkey = try P256.KeyAgreement.PublicKey(x963Representation: peerData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPubkey)

        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("SkyPinsBridge2024".utf8),
            sharedInfo: Data("session-key".utf8),
            outputByteCount: 32
        )
        symmetricKey = key
        sharedSecret = shared
        sendNonce = 0
        recvNonce = 0
    }

    /// 加密 -> nonce(12) || ciphertext || tag(16)
    func encrypt(plaintext: Data) throws -> Data {
        guard let key = symmetricKey else { throw CryptoError.notDerived }

        var nonceData = Data()
        nonceData.append(contentsOf: withUnsafeBytes(of: sendNonce.bigEndian) { Data($0) })
        var random = Data(count: 4)
        let ok = random.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 4, base)
        }
        if ok != 0 { throw CryptoError.randomFailed }
        nonceData.append(random)
        sendNonce &+= 1

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var out = Data()
        out.append(nonceData)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// 解密 <- nonce(12) || ciphertext || tag(16)
    func decrypt(packet: Data) throws -> Data {
        guard let key = symmetricKey else { throw CryptoError.notDerived }
        guard packet.count > 28 else { throw CryptoError.invalidB64 }

        let nonceData = packet.prefix(12)
        let tag = packet.suffix(16)
        let ciphertext = packet.dropFirst(12).dropLast(16)

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    func encryptJSON(_ obj: [String: Any]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: obj)
        return try encrypt(plaintext: json).base64EncodedString()
    }

    func decryptJSON(_ base64Str: String) throws -> [String: Any] {
        guard let data = Data(base64Encoded: base64Str) else { throw CryptoError.invalidB64 }
        let plain = try decrypt(packet: data)
        guard let obj = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw CryptoError.invalidJSON
        }
        return obj
    }
}

enum CryptoError: Error, LocalizedError {
    case invalidPublicKey
    case notDerived
    case invalidB64
    case invalidJSON
    case randomFailed

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey: "无效的 PC 公钥"
        case .notDerived:       "未完成密钥交换"
        case .invalidB64:       "无效的 Base64 数据"
        case .invalidJSON:      "无效的 JSON 数据"
        case .randomFailed:     "随机数生成失败"
        }
    }
}
