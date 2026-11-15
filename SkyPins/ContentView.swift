import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var state = AppState()
    @StateObject private var connection = PCConnection()

    @State private var nfcReader = NFCReader()
    @State private var showQRScanner = false
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: connectionIcon)
                            .font(.system(size: 44))
                            .foregroundColor(connectionColor)

                        Text(connection.status)
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        Text(state.pcHost.map { "已配对: \($0):\(state.pcPort)" } ?? "扫描 PC 二维码开始")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    HStack(spacing: 16) {
                        actionButton(icon: "qrcode.viewfinder", title: "配对",
                                     width: 76, color: .blue, disabled: false) {
                            showQRScanner = true
                        }

                        actionButton(icon: isProcessing ? "arrow.triangle.2.circlepath" : "radiowaves.right",
                                     title: "扫描徽章", width: 160,
                                     color: isProcessing ? .gray : .orange,
                                     disabled: isProcessing || !state.isConnected) {
                            scanBadge()
                        }

                        actionButton(icon: "xmark.circle", title: "断开",
                                     width: 76, color: .red, disabled: false) {
                            disconnect()
                        }
                    }

                    if !state.records.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("发送历史")
                                .font(.headline)
                                .foregroundColor(.gray)
                                .padding(.horizontal)

                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(state.records) { record in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(record.uid)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundColor(.white)
                                                Text("计数: \(record.counter)")
                                                    .font(.caption2)
                                                    .foregroundColor(.gray)
                                            }
                                            Spacer()
                                            statusBadge(record.status)
                                        }
                                        .padding(10)
                                        .background(Color.white.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .frame(maxHeight: 260)
                    }

                    Spacer(minLength: 0)

                    if let error = state.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView(onScan: handleScan, onDismiss: { showQRScanner = false })
                    .ignoresSafeArea()
            }
        }
        .onReceive(connection.$status) { newStatus in
            state.connectionStatus = newStatus
            state.isConnected = newStatus.hasPrefix("已配对")
        }
    }

    private func actionButton(icon: String, title: String, width: CGFloat,
                              color: Color, disabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title)
                Text(title).font(.caption)
            }
            .frame(width: width, height: 76)
            .background(color.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .disabled(disabled)
    }

    private var connectionIcon: String {
        if isProcessing { return "arrow.triangle.2.circlepath" }
        if state.isConnected { return "checkmark.shield.fill" }
        return "wifi.slash"
    }

    private var connectionColor: Color {
        if isProcessing { return .orange }
        if state.isConnected { return .green }
        return .gray
    }

    @ViewBuilder
    private func statusBadge(_ status: BadgeRecord.Status) -> some View {
        switch status {
        case .read:    Text("待发").font(.caption2)
        case .sending: ProgressView()
        case .sent:    Text("已送达").font(.caption2).foregroundColor(.green)
        case .failed:  Text("失败").font(.caption2).foregroundColor(.red)
        }
    }

    private func handleScan(_ code: String) {
        guard let data = code.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pubkey = json["pubkey"] as? String,
              let host = json["host"] as? String else {
            state.lastError = "无效的二维码格式"
            return
        }

        let port = (json["port"] as? Int) ?? 8765
        state.pcHost = host
        state.pcPort = port
        state.pcPubkeyBase64 = pubkey

        guard let wsURL = state.pcWebSocketURL else {
            state.lastError = "无法构造 WebSocket 地址"
            return
        }

        Task { @MainActor in
            do {
                state.lastError = nil
                try await connection.connect(url: wsURL, pcPubkey: pubkey)
            } catch {
                state.lastError = "连接失败: \(error.localizedDescription)"
            }
        }
    }

    private func scanBadge() {
        isProcessing = true
        state.lastError = nil

        nfcReader.scan { badge in
            Task { @MainActor in
                var record = badge
                record.status = .sending
                state.records.insert(record, at: 0)

                let rid = record.id
                do {
                    let st = try await connection.sendBadge(record)
                    if let idx = state.records.firstIndex(where: { $0.id == rid }) {
                        state.records[idx].status = (st == "ok") ? .sent : .failed
                    }
                    if st != "ok" { state.lastError = "PC 拒绝: \(st)" }
                } catch {
                    if let idx = state.records.firstIndex(where: { $0.id == rid }) {
                        state.records[idx].status = .failed
                    }
                    state.lastError = "发送失败: \(error.localizedDescription)"
                }
                isProcessing = false
            }
        } onError: { message in
            Task { @MainActor in
                state.lastError = message
                isProcessing = false
            }
        }
    }

    private func disconnect() {
        connection.disconnect()
        state.isConnected = false
        state.pcHost = nil
        state.pcPubkeyBase64 = nil
    }
}
