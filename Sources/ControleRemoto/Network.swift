import Darwin
import Foundation
import Network

/// WebSocket simples sobre URLSession, com os callbacks sempre na main thread.
/// As TVs usam certificado autoassinado na rede local, então aceitamos o certificado do servidor.
final class WebSocket: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((String?) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var opened = false
    private var finished = false
    private var pingTimer: Timer?

    init(url: URL) {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session.webSocketTask(with: url)
    }

    func open(timeout: TimeInterval = 4) {
        task.resume()
        receive()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.opened else { return }
            self.finish("A TV não respondeu")
        }
    }

    func send(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.finish(error.localizedDescription) }
        }
    }

    func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text)
    }

    /// Fecha sem chamar `onClose`.
    func close() {
        finished = true
        pingTimer?.invalidate()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func receive() {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                switch result {
                case .success(.string(let text)):
                    self.onText?(text)
                case .success(.data(let data)):
                    self.onText?(String(decoding: data, as: UTF8.self))
                case .success:
                    break
                case .failure(let error):
                    self.finish(error.localizedDescription)
                    return
                }
                self.receive()
            }
        }
    }

    private func finish(_ reason: String?) {
        guard !finished else { return }
        finished = true
        pingTimer?.invalidate()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        onClose?(reason)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened = true
        // Ping a cada 20 s: se a TV sumir da rede (desligada na tomada, IP novo), a conexão cai
        // em vez de ficar parecendo conectada.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.task.sendPing { error in
                guard error != nil else { return }
                DispatchQueue.main.async { self?.finish("A TV parou de responder") }
            }
        }
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish("A TV fechou a conexão")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error?.localizedDescription)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Procura TVs na rede local por SSDP e identifica Samsung (Tizen) e LG (webOS).
enum Discovery {
    struct Reply {
        let server: String
        let location: String
    }

    static func run() async -> [TVDevice] {
        let replies = await Task.detached { ssdpSearch(seconds: 3) }.value
        var found: [TVDevice] = []
        for (ip, list) in replies {
            let servers = list.map { $0.server.lowercased() }.joined(separator: " ")
            if servers.contains("samsung"), let tv = await samsung(at: ip) {
                found.append(tv)
            } else if servers.contains("webos"), let tv = await lg(at: ip, replies: list) {
                found.append(tv)
            }
        }
        return found.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static func samsung(at ip: String) async -> TVDevice? {
        guard let data = await HTTP.get("http://\(ip):8001/api/v2/"),
              let device = parseJSON(data)?["device"] as? [String: Any],
              (device["type"] as? String)?.contains("Samsung") == true else { return nil }
        let mac = (device["wifiMac"] as? String).flatMap(normalizeMAC) ?? arpMAC(for: ip)
        return TVDevice(id: device["id"] as? String ?? ip, name: device["name"] as? String ?? "Samsung",
                        brand: .samsung, host: ip, mac: mac)
    }

    private static func lg(at ip: String, replies: [Reply]) async -> TVDevice? {
        var name: String?
        var udn: String?
        for location in Set(replies.map(\.location)) where !location.isEmpty {
            guard let data = await HTTP.get(location),
                  let xml = String(data: data, encoding: .utf8),
                  let friendly = tag("friendlyName", in: xml) else { continue }
            // A descrição do renderizador da LG tem o nome que você deu para a TV.
            if xml.contains("LG Electronics") || name == nil {
                name = friendly
                udn = tag("UDN", in: xml)
            }
        }
        return TVDevice(id: udn ?? ip, name: name ?? "LG webOS", brand: .lg, host: ip, mac: arpMAC(for: ip))
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        let value = xml[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Manda um M-SEARCH e junta as respostas por IP.
    private static func ssdpSearch(seconds: TimeInterval) -> [String: [Reply]] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { Darwin.close(fd) }

        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)

        let message = Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n".utf8)
        for _ in 0..<2 {
            message.withUnsafeBytes { bytes in
                withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var replies: [String: [Reply]] = [:]
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            var headers: [String: String] = [:]
            for line in String(decoding: buffer[0..<count], as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].uppercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            replies[ip, default: []].append(Reply(server: headers["SERVER"] ?? "", location: headers["LOCATION"] ?? ""))
        }
        return replies
    }

    /// O MAC sai da tabela ARP, que o próprio SSDP acabou de preencher.
    static func arpMAC(for ip: String) -> String? {
        guard let match = arp(["-n", ip]).firstMatch(of: /at ([0-9a-fA-F:]+)/) else { return nil }
        return normalizeMAC(String(match.1))
    }

    /// Plano B quando o SSDP não acha a TV (alguns roteadores filtram multicast): varre a
    /// sub-rede /24 do IP antigo. A Samsung é confirmada pelo UUID; a LG pela porta do webOS,
    /// fora dos IPs de outras TVs conhecidas. Devolve o IP novo, se achou um só.
    static func sweep(for device: TVDevice, excluding known: Set<String>) async -> String? {
        let parts = device.host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let prefix = parts.prefix(3).joined(separator: ".")
        let candidates = (1...254).map { "\(prefix).\($0)" }.filter { !known.contains($0) }

        let hits = await withTaskGroup(of: String?.self) { group -> [String] in
            for ip in candidates {
                group.addTask {
                    switch device.brand {
                    case .samsung:
                        guard let data = await HTTP.get("http://\(ip):8001/api/v2/", timeout: 2),
                              let info = parseJSON(data)?["device"] as? [String: Any],
                              info["id"] as? String == device.id else { return nil }
                        return ip
                    case .lg:
                        return await isOpen(ip, port: 3001) ? ip : nil
                    }
                }
            }
            var hits: [String] = []
            for await ip in group { if let ip { hits.append(ip) } }
            return hits
        }
        return hits.count == 1 ? hits[0] : nil
    }

    static func isOpen(_ host: String, port: UInt16, timeout: TimeInterval = 1.5) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish: (Bool) -> Void = { open in
                once.run { continuation.resume(returning: open) }
                connection.cancel()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private static func arp(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func normalizeMAC(_ mac: String) -> String? {
        let parts = mac.split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ UInt8($0, radix: 16) != nil }) else { return nil }
        return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").lowercased()
    }
}

/// Garante que uma continuação seja retomada uma vez só.
final class Once {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

enum WakeOnLAN {
    /// Pacote mágico em broadcast e direto para o IP da TV (que ainda está no cache ARP).
    static func send(mac: String, host: String) {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var targets = ["255.255.255.255", host]
        if let last = host.lastIndex(of: ".") { targets.append(host[..<last] + ".255") }
        for target in targets {
            for port: UInt16 in [9, 7] {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                inet_pton(AF_INET, target, &address.sin_addr)
                packet.withUnsafeBytes { raw in
                    withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }
}
