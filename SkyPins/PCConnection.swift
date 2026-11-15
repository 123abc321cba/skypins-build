import Foundation

/// WebSocket 连接管理 (非 MainActor, 内部自带串行队列保证状态一致)
/// 协议:
///   1. 连接 ws://host:port/badge
///   2. 收 server_hello {pubkey}
///   3. 发 pairing {phone_pubkey, data: AESGCM({type:"pairing", fingerprint})}
///   4. 发 badge   {phone_pubkey, data: AESGCM({type:"badge", uid, counter, token, url})}
///   5. 收 ack     {status: "ok"|"error", message}
final class PCConnection: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var status = "未连接"

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let crypto = CryptoBox()
    private let queue = DispatchQueue(label: "skypins.pc.conn")

    override init() { super.init() }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    // MARK: - 连接与握手

    func connect(url: URL, pcPubkey: String) async throws {
        queue.sync {
            task?.cancel(with: .goingAway, reason: nil)
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            session = URLSession(configuration: cfg)
            task = session?.webSocketTask(with: url)
            task?.resume()
        }
        setStatus("等待 PC 握手...")

        guard let hello = try await receiveJSON(),
              let serverPubkey = hello["pubkey"] as? String else {
            throw ConnectionError.badHandshake
        }

        try crypto.derive(peerPubkeyBase64: serverPubkey)
        setStatus("密钥交换完成")

        let pairing: [String: Any] = [
            "phone_pubkey": crypto.publicKeyBase64,
            "data": try crypto.encryptJSON(["type": "pairing", "fingerprint": crypto.fingerprint])
        ]
        try await sendJSON(pairing)

        // 可选 ack, 超时不阻塞
        if let ack = try? await receiveJSON(), let st = ack["status"] as? String {
            if st != "ok" { throw ConnectionError.badAck }
        }
        setStatus("已配对 ✓")
    }

    // MARK: - 发送徽章

    func sendBadge(_ badge: BadgeRecord) async throws -> String {
        guard task != nil else { throw ConnectionError.notConnected }

        let payload: [String: Any] = [
            "phone_pubkey": crypto.publicKeyBase64,
            "data": try crypto.encryptJSON([
                "type": "badge",
                "uid": badge.uid,
                "counter": badge.counter,
                "token": badge.token,
                "url": badge.rawURL,
                "ts": Int(Date().timeIntervalSince1970)
            ])
        ]
        try await sendJSON(payload)

        guard let ack = try await receiveJSON(),
              let st = ack["status"] as? String else {
            throw ConnectionError.badAck
        }
        return st
    }

    // MARK: - 关闭

    func disconnect() {
        queue.sync {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            session?.invalidateAndCancel()
            session = nil
        }
        setStatus("已断开")
    }

    // MARK: - 底层收发

    private func sendJSON(_ dict: [String: Any]) async throws {
        guard let t = task else { throw ConnectionError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: dict)
        try await t.send(.data(data))
    }

    private func receiveJSON() async throws -> [String: Any]? {
        guard let t = task else { throw ConnectionError.notConnected }
        let msg = try await t.receive()
        let data: Data
        switch msg {
        case .data(let d):   data = d
        case .string(let s): guard let d = s.data(using: .utf8) else { return nil }; data = d
        @unknown default:    return nil
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum ConnectionError: Error, LocalizedError {
    case notConnected
    case badHandshake
    case badAck

    var errorDescription: String? {
        switch self {
        case .notConnected:  "未连接到 PC"
        case .badHandshake:  "PC 握手失败"
        case .badAck:        "PC 响应异常"
        }
    }
}
