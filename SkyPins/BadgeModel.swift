import Foundation
import Combine

struct BadgeRecord: Identifiable, Codable {
    let id: UUID
    let uid: String
    var counter: Int
    let token: String
    let rawURL: String
    let timestamp: Date
    var status: Status

    enum Status: String, Codable {
        case read
        case sending
        case sent
        case failed
    }

    init(uid: String, counter: Int, token: String, rawURL: String) {
        self.id = UUID()
        self.uid = uid
        self.counter = counter
        self.token = token
        self.rawURL = rawURL
        self.timestamp = Date()
        self.status = .read
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var connectionStatus = "未连接"
    @Published var isConnected = false
    @Published var records: [BadgeRecord] = []
    @Published var lastError: String?

    @Published var pcHost: String?
    @Published var pcPort: Int = 8765
    @Published var pcPubkeyBase64: String?

    var pcWebSocketURL: URL? {
        guard let host = pcHost else { return nil }
        return URL(string: "ws://\(host):\(pcPort)/badge")
    }
}
