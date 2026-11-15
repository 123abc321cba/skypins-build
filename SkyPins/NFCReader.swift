import CoreNFC
import Foundation

/// NFC NDEF 徽章读取器
/// 读取光遇 NFC 徽章的 NDEF URL: https://sky.thatg.co/?s=TOKEN&c=UIDxCOUNTER
///
/// 并发模型: 非 @MainActor。CoreNFC 回调在后台队列, 对外回调统一切回主线程派发。
final class NFCReader: NSObject, @unchecked Sendable {
    private var session: NFCTagReaderSession?
    private var onSuccess: ((BadgeRecord) -> Void)?
    private var onError: ((String) -> Void)?

    func scan(onSuccess: @escaping (BadgeRecord) -> Void, onError: @escaping (String) -> Void) {
        guard NFCTagReaderSession.readingAvailable else {
            Self.deliver { onError("此设备不支持或未开启 NFC 读取") }
            return
        }

        self.onSuccess = onSuccess
        self.onError = onError

        guard let s = NFCTagReaderSession(pollingOption: .iso14443, delegate: self) else {
            Self.deliver { onError("NFC 会话创建失败") }
            return
        }
        s.alertMessage = "将 NFC 徽章靠近手机顶部"
        session = s
        s.begin()
    }

    func cancel() {
        session?.invalidate()
        session = nil
    }

    // MARK: - 主线程派发

    private static func deliver(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func fail(_ message: String) {
        let cb = onError
        onError = nil
        onSuccess = nil
        Self.deliver { cb?(message) }
    }

    private func succeed(_ badge: BadgeRecord) {
        let cb = onSuccess
        onError = nil
        onSuccess = nil
        Self.deliver { cb?(badge) }
    }

    // MARK: - 徽章 URL 解析

    /// 解析 https://sky.thatg.co/?s=TOKEN&c=UIDxCOUNTER
    static func parseBadgeURL(_ url: String) -> (url: String, valid: Bool, uid: String, counter: Int, token: String) {
        let cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        guard let comp = URLComponents(string: cleaned) else {
            return (cleaned, false, "", 0, "")
        }

        var params: [String: String] = [:]
        for item in comp.queryItems ?? [] {
            params[item.name] = item.value
        }

        let token = params["s"] ?? ""
        let counterStr = params["c"] ?? ""

        var uid = ""
        var counter = 0

        let parts = counterStr.components(separatedBy: CharacterSet(charactersIn: "xX"))
        if let first = parts.first, !first.isEmpty {
            uid = first.uppercased()
        }
        if parts.count >= 2, let c = Int(parts[1], radix: 16) {
            counter = c
        }

        return (cleaned, !token.isEmpty && !uid.isEmpty, uid, counter, token)
    }
}

// MARK: - NFCTagReaderSessionDelegate

extension NFCReader: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        self.session = nil
        if let e = error as? NFCReaderError {
            switch e.code {
            case .readerSessionInvalidationErrorFirstNDEFTagRead,
                 .readerSessionInvalidationErrorUserCanceled:
                onError = nil
                onSuccess = nil
                return
            default:
                break
            }
        }
        fail("NFC 会话结束: \(error.localizedDescription)")
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else {
            session.invalidate(errorMessage: "未检测到 NFC 标签")
            return
        }

        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: "连接失败: \(error.localizedDescription)")
                _ = error
                return
            }

            let ndefTag: NFCNDEFTag
            switch tag {
            case .miFare(let t):    ndefTag = t
            case .iso7816(let t):   ndefTag = t
            case .feliCa(let t):    ndefTag = t
            case .iso15693(let t):  ndefTag = t
            @unknown default:
                session.invalidate(errorMessage: "不支持的标签类型")
                return
            }

            ndefTag.queryNDEFStatus { status, _, error in
                if let error {
                    session.invalidate(errorMessage: "查询失败: \(error.localizedDescription)")
                    return
                }
                guard status == .readWrite || status == .readOnly else {
                    session.invalidate(errorMessage: "标签不支持 NDEF")
                    return
                }

                ndefTag.readNDEF { message, error in
                    if let error {
                        session.invalidate(errorMessage: "读取失败: \(error.localizedDescription)")
                        return
                    }
                    guard let message,
                          let record = message.records.first,
                          let payload = String(data: record.payload, encoding: .utf8) else {
                        session.invalidate(errorMessage: "不是光遇徽章")
                        return
                    }

                    let parsed = NFCReader.parseBadgeURL(payload)
                    guard parsed.valid else {
                        session.invalidate(errorMessage: "未识别的徽章格式")
                        return
                    }

                    let badge = BadgeRecord(uid: parsed.uid,
                                            counter: parsed.counter,
                                            token: parsed.token,
                                            rawURL: parsed.url)

                    session.alertMessage = "读取成功: \(parsed.uid)"
                    session.invalidate()
                    _ = self
                    self.succeed(badge)
                }
            }
        }
    }
}
