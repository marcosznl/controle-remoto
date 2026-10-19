import Foundation

/// Conexão com uma TV. Cada marca é uma subclasse; a interface só conversa com esta base.
/// Tudo roda na main thread (os sockets já entregam os callbacks nela).
class TVSession: ObservableObject {
    @Published var device: TVDevice
    @Published var status: ConnectionStatus = .idle {
        didSet { if status.isConnected { waking = false } }
    }
    /// Volume de 0 a 100; nil quando a TV não informa (Samsung pela rede local).
    @Published var volume: Int?
    @Published var muted: Bool?
    @Published var nowPlaying: NowPlaying?
    @Published var apps: [TVApp] = []
    @Published var inputs: [TVInput] = []
    /// Mandamos o Wake-on-LAN e estamos esperando a TV acordar.
    @Published var waking = false

    /// A TV entregou um token novo (ou ele deixou de valer): quem guarda as TVs salva.
    var onDeviceChange: ((TVDevice) -> Void)?

    var supportsAbsoluteVolume: Bool { false }
    var supportsMuteState: Bool { false }

    private var wakeGeneration = 0

    init(device: TVDevice) {
        self.device = device
    }

    static func make(for device: TVDevice) -> TVSession {
        switch device.brand {
        case .samsung: SamsungSession(device: device)
        case .lg: LGSession(device: device)
        }
    }

    func connect() {}
    func disconnect() {}
    func press(_ key: RemoteKey) {}
    func setVolume(_ value: Int) {}
    func setMuted(_ on: Bool) { press(.mute) }
    func powerOff() {}
    func launch(_ app: TVApp) {}
    func switchInput(_ input: TVInput) {}

    // MARK: Ponteiro e canais

    /// Canal na tela agora, quando a TV informa (LG).
    @Published var currentChannel: FavoriteChannel?
    var supportsPointer: Bool { false }

    func movePointer(dx: Double, dy: Double) {}
    func clickPointer() {}
    func scrollPointer(dy: Double) {}
    func tune(_ channel: FavoriteChannel) {}

    func addFavorite(_ channel: FavoriteChannel) {
        var list = device.favorites ?? []
        guard !list.contains(where: { $0.number == channel.number }) else { return }
        list.append(channel)
        device.favorites = list
        onDeviceChange?(device)
    }

    func removeFavorite(_ channel: FavoriteChannel) {
        device.favorites?.removeAll { $0.number == channel.number }
        onDeviceChange?(device)
    }

    func togglePower() {
        if status.isConnected { powerOff() } else if status != .pairing { powerOn() }
    }

    func reconnect() {
        disconnect()
        connect()
    }

    /// Esquece o token e conecta de novo, o que faz a TV mostrar o pedido de permissão.
    func forgetPairing() {
        disconnect()
        saveToken(nil)
        connect()
    }

    func saveToken(_ token: String?) {
        guard token != device.token else { return }
        device.token = token
        onDeviceChange?(device)
    }

    /// Wake-on-LAN e tentativas de conexão a cada 3 s por cerca de 45 s.
    func powerOn() {
        wake()
        waking = true
        wakeGeneration += 1
        retryConnect(generation: wakeGeneration, attempts: 15)
    }

    private func wake() {
        for mac in [device.mac, device.altMAC].compactMap({ $0 }) {
            WakeOnLAN.send(mac: mac, host: device.host)
        }
    }

    private func retryConnect(generation: Int, attempts: Int) {
        connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.wakeGeneration == generation, self.waking else { return }
            guard attempts > 1 else { self.waking = false; return }
            if self.status != .pairing {
                self.wake()
                self.retryConnect(generation: generation, attempts: attempts - 1)
            }
        }
    }
}

// MARK: - Samsung (Tizen)

/// Samsung Tizen 2016+: WebSocket em wss://IP:8002 com token de pareamento.
/// Pela rede local a Samsung só aceita teclas, então o volume é relativo (+/−).
final class SamsungSession: TVSession {
    private var socket: WebSocket?
    private var active = false
    private var probing = false
    private var pendingPowerKey = false

    /// IDs de apps Tizen conhecidos. Os firmwares novos não respondem à lista de apps pelo
    /// WebSocket, então perguntamos à API REST por cada um: só aparecem os instalados, com o
    /// nome que a própria TV informa (um ID errado aqui é só ignorado).
    static let knownAppIDs = [
        "3201907018807", // Netflix
        "111299001912", // YouTube
        "3201910019365", // Prime Video
        "3201901017640", // Disney+
        "3201807016597", // Apple TV
        "3201908019041", // Apple Music
        "3202301029760", // HBO Max
        "3202203026841", // Twitch
        "3201606009684", // Spotify
        "3201512006963", // Plex
        "3201710014981", // Paramount+
        "3201707014489", // Samsung TV Plus
        "3201601007250", // Google Play Filmes
        "3201611010983", // Deezer
        "3201802015604", // Globoplay
        "3201909019175", // Crunchyroll
        "3201804016022", // Pluto TV
        "3202008021577", // Star+
        "3201908019020", // YouTube Kids
    ]

    private var restApps: [TVApp] = []

    override init(device: TVDevice) {
        super.init(device: device)
        inputs = [
            TVInput(id: "KEY_TV", label: "TV ao vivo"),
            TVInput(id: "KEY_HDMI1", label: "HDMI 1"),
            TVInput(id: "KEY_HDMI2", label: "HDMI 2"),
            TVInput(id: "KEY_HDMI3", label: "HDMI 3"),
            TVInput(id: "KEY_SOURCE", label: "Menu de fontes"),
        ]
    }

    override func connect() {
        active = true
        guard socket == nil, !probing else { return }
        probing = true
        // Nas novas tentativas em segundo plano o status fica como está, sem piscar "Conectando".
        if status == .idle || status == .denied { status = .connecting }
        let host = device.host
        Task {
            // A API REST responde até em espera e diz se a tela está ligada.
            let data = await HTTP.get("http://\(host):8001/api/v2/", timeout: 2)
            let info = data.flatMap { parseJSON($0) }?["device"] as? [String: Any]
            let power = info?["PowerState"] as? String
            await MainActor.run {
                self.probing = false
                guard self.active, self.socket == nil else { return }
                if data == nil {
                    self.status = .offline(nil)
                } else if power == "standby" && !self.pendingPowerKey {
                    self.status = .standby
                } else {
                    self.openSocket()
                }
            }
        }
    }

    private func openSocket() {
        let name = Data("Controle Remoto".utf8).base64EncodedString()
        var address = "wss://\(device.host):8002/api/v2/channels/samsung.remote.control?name=\(name)"
        if let token = device.token { address += "&token=\(token)" }
        guard let url = URL(string: address) else { return }

        let ws = WebSocket(url: url)
        ws.onOpen = { [weak self, weak ws] in
            // Com token a TV responde na hora; sem ele, mostra o pedido de permissão.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let self, self.socket === ws, self.status == .connecting else { return }
                self.status = .pairing
            }
        }
        ws.onText = { [weak self] in self?.handle($0) }
        ws.onClose = { [weak self, weak ws] reason in
            guard let self, self.socket === ws else { return }
            self.socket = nil
            if self.status != .denied && self.status != .standby { self.status = .offline(reason) }
        }
        socket = ws
        status = device.token == nil ? .pairing : .connecting
        ws.open(timeout: 5)
    }

    private func handle(_ text: String) {
        if ProcessInfo.processInfo.environment["CR_DEBUG"] != nil { print("← \(text.prefix(400))") }
        guard let message = parseJSON(text), let event = message["event"] as? String else { return }
        let data = message["data"] as? [String: Any]
        switch event {
        case "ms.channel.connect":
            if let token = data?["token"] { saveToken("\(token)") }
            status = .connected
            if pendingPowerKey {
                pendingPowerKey = false
                send(key: "KEY_POWER")
            }
            requestApps()
        case "ms.channel.unauthorized":
            status = .denied
            dropSocket()
        case "ms.channel.timeOut":
            status = .offline("O pedido na TV expirou")
            dropSocket()
        case "ed.installedApp.get":
            let list = (data?["data"] as? [[String: Any]]) ?? []
            let installed = list.compactMap { app -> TVApp? in
                guard let id = app["appId"] as? String, let name = app["name"] as? String else { return nil }
                return TVApp(id: id, title: name, kind: app["app_type"] as? Int ?? 2)
            }
            if !installed.isEmpty {
                apps = installed.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            }
        default:
            break
        }
    }

    /// Desligada pelo controle físico, a Samsung fica em espera mas o socket continua aberto;
    /// a API REST é quem diz se a tela apagou.
    func refreshPowerState() {
        guard status.isConnected else { return }
        let host = device.host
        Task {
            let data = await HTTP.get("http://\(host):8001/api/v2/", timeout: 2)
            let power = (data.flatMap { parseJSON($0) }?["device"] as? [String: Any])?["PowerState"] as? String
            await MainActor.run {
                guard self.status.isConnected, power == "standby" else { return }
                self.status = .standby
                self.nowPlaying = nil
                self.dropSocket()
            }
        }
    }

    private func requestApps() {
        socket?.sendJSON(["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
        refreshApps()
    }

    /// Pergunta à API REST por cada app conhecido: quais existem, e qual está na tela.
    func refreshApps() {
        let host = device.host
        Task {
            let found = await withTaskGroup(of: (TVApp, Bool)?.self) { group -> [(TVApp, Bool)] in
                for id in Self.knownAppIDs {
                    group.addTask {
                        guard let data = await HTTP.get("http://\(host):8001/api/v2/applications/\(id)"),
                              let info = parseJSON(data), let name = info["name"] as? String else { return nil }
                        return (TVApp(id: id, title: name), info["visible"] as? Bool ?? false)
                    }
                }
                var found: [(TVApp, Bool)] = []
                for await item in group { if let item { found.append(item) } }
                return found
            }
            await MainActor.run {
                guard self.status.isConnected else { return }
                if !found.isEmpty {
                    self.restApps = found.map(\.0).sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
                    // A lista pelo WebSocket (quando o firmware responde) é mais completa.
                    if self.apps.count <= self.restApps.count { self.apps = self.restApps }
                }
                if let visible = found.first(where: \.1)?.0 {
                    self.onLiveTV = false
                    self.nowPlaying = NowPlaying(title: visible.title, subtitle: "APP")
                } else if self.nowPlaying?.subtitle == "APP" {
                    self.nowPlaying = nil
                }
            }
        }
    }

    func send(key: String) {
        socket?.sendJSON([
            "method": "ms.remote.control",
            "params": ["Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ])
    }

    private func dropSocket() {
        let ws = socket
        socket = nil
        ws?.close()
    }

    override func disconnect() {
        active = false
        pendingPowerKey = false
        dropSocket()
        status = .idle
    }

    override func press(_ key: RemoteKey) {
        send(key: Self.code(for: key))
    }

    override func powerOff() {
        send(key: "KEY_POWER")
        status = .standby
        nowPlaying = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.dropSocket() }
    }

    override func powerOn() {
        // Em espera a Samsung continua na rede: a tecla de power pelo socket liga a tela.
        if status == .standby {
            pendingPowerKey = true
            active = true
            if socket == nil && !probing { openSocket() }
        }
        super.powerOn()
    }

    func launchBySocket(_ id: String, type: String = "NATIVE_LAUNCH") {
        socket?.sendJSON([
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host", "data": ["appId": id, "action_type": type]],
        ])
    }

    /// Abre pela API REST (o que os firmwares novos aceitam); se falhar, tenta pelo WebSocket.
    override func launch(_ app: TVApp) {
        onLiveTV = false
        nowPlaying = NowPlaying(title: app.title, subtitle: "APP")
        let host = device.host
        Task {
            let ok = await HTTP.post("http://\(host):8001/api/v2/applications/\(app.id)")
            guard !ok else { return }
            await MainActor.run {
                self.socket?.sendJSON([
                    "method": "ms.channel.emit",
                    "params": [
                        "event": "ed.apps.launch", "to": "host",
                        "data": ["appId": app.id, "action_type": app.kind == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK"],
                    ],
                ])
            }
        }
    }

    override func switchInput(_ input: TVInput) {
        if input.id == "KEY_TV" {
            goToLiveTV()
        } else {
            send(key: input.id)
        }
        if input.id != "KEY_SOURCE" && input.id != "KEY_TV" {
            onLiveTV = false
            nowPlaying = NowPlaying(title: input.label, subtitle: "ENTRADA")
        }
    }

    // MARK: Canais (Samsung)

    /// Vai para a TV ao vivo (se já não estiver) e digita o número do canal.
    override func tune(_ channel: FavoriteChannel) {
        let digits = channel.number.split(whereSeparator: { $0 == "-" || $0 == "." }).first.map(String.init) ?? channel.number
        let start = onLiveTV ? 0 : goToLiveTV() + 0.8
        for (index, digit) in digits.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(index) * 0.35) { [weak self] in
                self?.send(key: "KEY_\(digit)")
            }
        }
        onLiveTV = true
        nowPlaying = NowPlaying(title: "CH \(channel.number)", subtitle: channel.name.isEmpty ? "TV AO VIVO" : channel.name.uppercased())
    }

    /// Estamos na TV ao vivo (fomos para lá e nenhum app abriu depois).
    private var onLiveTV = false

    /// As Samsung recentes ignoram KEY_TV/KEY_DTV/KEY_ANTENA. A lista de canais funciona de
    /// qualquer app: vai para a TV ao vivo (antena e Samsung TV Plus juntos, no último canal
    /// visto) com a lista aberta por cima, e o Voltar fecha só a lista. Devolve quanto leva.
    @discardableResult
    func goToLiveTV() -> Double {
        send(key: "KEY_CH_LIST")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.send(key: "KEY_RETURN")
        }
        onLiveTV = true
        nowPlaying = NowPlaying(title: "TV ao vivo", subtitle: "TV AO VIVO")
        return 1.8
    }

    static func code(for key: RemoteKey) -> String {
        switch key {
        case .up: "KEY_UP"
        case .down: "KEY_DOWN"
        case .left: "KEY_LEFT"
        case .right: "KEY_RIGHT"
        case .ok: "KEY_ENTER"
        case .back: "KEY_RETURN"
        case .home: "KEY_HOME"
        case .menu: "KEY_MENU"
        case .info: "KEY_INFO"
        case .exit: "KEY_EXIT"
        case .play: "KEY_PLAY"
        case .pause: "KEY_PAUSE"
        case .rewind: "KEY_REWIND"
        case .fastForward: "KEY_FF"
        case .channelUp: "KEY_CHUP"
        case .channelDown: "KEY_CHDOWN"
        case .volumeUp: "KEY_VOLUP"
        case .volumeDown: "KEY_VOLDOWN"
        case .mute: "KEY_MUTE"
        case .digit(let n): "KEY_\(n)"
        }
    }
}

// MARK: - LG (webOS)

/// LG webOS: protocolo SSAP em wss://IP:3001 (ou ws://IP:3000 nos modelos antigos).
/// As setas e o OK vão por um segundo socket, o de "pointer input".
final class LGSession: TVSession {
    private typealias Handler = (_ payload: [String: Any], _ ok: Bool) -> Void

    private var socket: WebSocket?
    private var pointer: WebSocket?
    private var pointerOpen = false
    private var pointerRequested = false
    private var pointerQueue: [String] = []
    private var active = false
    private var nextID = 0
    private var handlers: [String: Handler] = [:]
    private var subscriptions: Set<String> = []
    private var foregroundApp = ""
    private var channel: NowPlaying?
    private var inputApps: [String: String] = [:]

    override var supportsAbsoluteVolume: Bool { true }
    override var supportsMuteState: Bool { true }

    override func connect() {
        active = true
        guard socket == nil else { return }
        if status == .idle || status == .denied { status = .connecting }
        open(secure: true)
    }

    private func open(secure: Bool) {
        guard let url = URL(string: secure ? "wss://\(device.host):3001" : "ws://\(device.host):3000") else { return }
        let ws = WebSocket(url: url)
        ws.onOpen = { [weak self] in self?.register() }
        ws.onText = { [weak self] in self?.handle($0) }
        ws.onClose = { [weak self, weak ws] reason in
            guard let self, self.socket === ws else { return }
            self.socket = nil
            self.resetChannels()
            // webOS antigos só aceitam ws:// na porta 3000.
            if secure, self.active, self.status != .denied, self.status != .pairing {
                if self.status.isConnected { self.status = .connecting }
                self.open(secure: false)
                return
            }
            if self.status != .denied { self.status = .offline(reason) }
        }
        socket = ws
        ws.open()
    }

    private func register() {
        var payload = Self.registration
        if let key = device.token { payload["client-key"] = key }
        socket?.sendJSON(["type": "register", "id": "register_0", "payload": payload])
    }

    private func handle(_ text: String) {
        guard let message = parseJSON(text) else { return }
        let type = message["type"] as? String ?? ""
        let id = message["id"] as? String ?? ""
        let payload = message["payload"] as? [String: Any] ?? [:]

        if id == "register_0" {
            switch type {
            case "registered":
                if let key = payload["client-key"] as? String { saveToken(key) }
                status = .connected
                didConnect()
            case "response" where payload["pairingType"] as? String == "PROMPT":
                status = .pairing
            case "error":
                let error = (message["error"] as? String ?? "").lowercased()
                if error.contains("403") || error.contains("denied") || error.contains("cancel") {
                    status = .denied
                    let ws = socket
                    socket = nil
                    ws?.close()
                    resetChannels()
                } else {
                    status = .offline(error)
                }
            default:
                break
            }
            return
        }

        guard let handler = handlers[id] else { return }
        if !subscriptions.contains(id) { handlers[id] = nil }
        handler(payload, type != "error" && (payload["returnValue"] as? Bool ?? true))
    }

    @discardableResult
    private func request(_ uri: String, _ payload: [String: Any]? = nil, subscribe: Bool = false,
                         then handler: Handler? = nil) -> String {
        nextID += 1
        let id = "\(subscribe ? "sub" : "req")_\(nextID)"
        if let handler { handlers[id] = handler }
        if subscribe { subscriptions.insert(id) }
        var message: [String: Any] = ["type": subscribe ? "subscribe" : "request", "id": id, "uri": uri]
        if let payload { message["payload"] = payload }
        socket?.sendJSON(message)
        return id
    }

    private func didConnect() {
        request("ssap://audio/getVolume", subscribe: true) { [weak self] payload, ok in
            if ok { self?.applyVolume(payload) }
        }
        request("ssap://com.webos.applicationManager/listLaunchPoints") { [weak self] payload, _ in
            guard let self else { return }
            let list = payload["launchPoints"] as? [[String: Any]] ?? []
            self.apps = list.compactMap { app -> TVApp? in
                guard let id = app["id"] as? String, let title = app["title"] as? String else { return nil }
                let icon = (app["largeIcon"] as? String) ?? (app["icon"] as? String)
                return TVApp(id: id, title: title, iconURL: icon.flatMap(URL.init(string:)))
            }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            self.refreshNowPlaying()
        }
        request("ssap://tv/getExternalInputList") { [weak self] payload, _ in
            guard let self else { return }
            let list = payload["devices"] as? [[String: Any]] ?? []
            var inputs = [TVInput(id: "livetv", label: "TV ao vivo")]
            for device in list {
                guard let id = device["id"] as? String else { continue }
                let label = device["label"] as? String ?? id
                inputs.append(TVInput(id: id, label: label, connected: device["connected"] as? Bool ?? true))
                if let appID = device["appId"] as? String { self.inputApps[appID] = label }
            }
            self.inputs = inputs
            self.refreshNowPlaying()
        }
        request("ssap://com.webos.applicationManager/getForegroundAppInfo", subscribe: true) { [weak self] payload, ok in
            guard let self, ok else { return }
            self.foregroundApp = payload["appId"] as? String ?? ""
            if self.foregroundApp.contains("livetv") { self.refreshChannel() }
            self.refreshNowPlaying()
        }
        request("ssap://tv/getCurrentChannel", subscribe: true) { [weak self] payload, ok in
            if ok { self?.applyChannel(payload) }
        }
        // Os MACs permitem ligar a TV pela rede (Wake-on-LAN). A LG informa o do cabo e o do
        // Wi-Fi sem dizer qual está em uso, e o do cabo não acorda a TV pelo Wi-Fi: guardamos os
        // dois e o Wake-on-LAN vai para ambos.
        request("ssap://com.webos.service.connectionmanager/getinfo") { [weak self] payload, ok in
            guard let self, ok else { return }
            func mac(_ key: String) -> String? {
                ((payload[key] as? [String: Any])?["macAddress"] as? String).flatMap(Discovery.normalizeMAC)
            }
            let wifi = mac("wifiInfo"), wired = mac("wiredInfo")
            guard let main = wifi ?? wired else { return }
            let other = main == wifi ? wired : nil
            guard main != self.device.mac || other != self.device.altMAC else { return }
            self.device.mac = main
            self.device.altMAC = other
            self.onDeviceChange?(self.device)
        }
        openPointer()
    }

    private func applyVolume(_ payload: [String: Any]) {
        // webOS 5+ manda dentro de volumeStatus; os antigos mandam solto.
        let info = payload["volumeStatus"] as? [String: Any] ?? payload
        if let value = info["volume"] as? Int { volume = value >= 0 ? value : nil }
        if let mute = (info["muteStatus"] ?? info["muted"] ?? info["mute"]) as? Bool { muted = mute }
    }

    private func applyChannel(_ payload: [String: Any]) {
        guard let number = payload["channelNumber"] as? String else { return }
        let name = payload["channelName"] as? String ?? "TV ao vivo"
        channel = NowPlaying(title: "CH \(number)", subtitle: name.uppercased())
        currentChannel = FavoriteChannel(number: number, name: name, channelID: payload["channelId"] as? String)
        refreshNowPlaying()
    }

    private func refreshChannel() {
        request("ssap://tv/getCurrentChannel") { [weak self] payload, ok in
            if ok { self?.applyChannel(payload) }
        }
    }

    private func refreshNowPlaying() {
        let app = foregroundApp
        if !app.contains("livetv") { currentChannel = nil }
        if app.isEmpty {
            nowPlaying = nil
        } else if app.contains("livetv") {
            nowPlaying = channel ?? NowPlaying(title: "TV ao vivo", subtitle: "LIVE TV")
            return
        } else if let label = inputApps[app] {
            nowPlaying = NowPlaying(title: label, subtitle: "ENTRADA")
        } else {
            let title = apps.first { $0.id == app }?.title ?? app.components(separatedBy: ".").last?.capitalized ?? app
            nowPlaying = NowPlaying(title: title, subtitle: "APP")
        }
    }

    // MARK: Pointer input (setas, OK, voltar…)

    private func openPointer() {
        guard pointer == nil, !pointerRequested, socket != nil else { return }
        pointerRequested = true
        request("ssap://com.webos.service.networkinput/getPointerInputSocket") { [weak self] payload, ok in
            guard let self else { return }
            guard ok, let path = payload["socketPath"] as? String, let url = URL(string: path) else {
                self.pointerRequested = false
                return
            }
            let ws = WebSocket(url: url)
            ws.onOpen = { [weak self, weak ws] in
                guard let self, let ws, self.pointer === ws else { return }
                self.pointerOpen = true
                self.pointerQueue.forEach(ws.send)
                self.pointerQueue.removeAll()
            }
            ws.onClose = { [weak self, weak ws] _ in
                guard let self, self.pointer === ws else { return }
                self.pointer = nil
                self.pointerOpen = false
                self.pointerRequested = false
            }
            self.pointer = ws
            ws.open()
        }
    }

    private func button(_ name: String) {
        pointerSend("type:button\nname:\(name)\n\n")
    }

    private func pointerSend(_ message: String) {
        if let pointer, pointerOpen {
            pointer.send(message)
        } else {
            pointerQueue.append(message)
            openPointer()
        }
    }

    private func resetChannels() {
        pointer?.close()
        pointer = nil
        pointerOpen = false
        pointerRequested = false
        pointerQueue.removeAll()
        handlers.removeAll()
        subscriptions.removeAll()
    }

    // MARK: Comandos

    override func disconnect() {
        active = false
        let ws = socket
        socket = nil
        ws?.close()
        resetChannels()
        status = .idle
    }

    override func press(_ key: RemoteKey) {
        switch key {
        case .volumeUp: request("ssap://audio/volumeUp")
        case .volumeDown: request("ssap://audio/volumeDown")
        case .mute: setMuted(!(muted ?? false))
        case .channelUp, .channelDown:
            request(key == .channelUp ? "ssap://tv/channelUp" : "ssap://tv/channelDown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshChannel() }
        case .play: request("ssap://media.controls/play")
        case .pause: request("ssap://media.controls/pause")
        case .rewind: request("ssap://media.controls/rewind")
        case .fastForward: request("ssap://media.controls/fastForward")
        case .up: button("UP")
        case .down: button("DOWN")
        case .left: button("LEFT")
        case .right: button("RIGHT")
        case .ok: button("ENTER")
        case .back: button("BACK")
        case .home: button("HOME")
        case .menu: button("MENU")
        case .info: button("INFO")
        case .exit: button("EXIT")
        case .digit(let n): button("\(n)")
        }
    }

    // MARK: Touchpad e canais (LG)

    override var supportsPointer: Bool { true }

    override func movePointer(dx: Double, dy: Double) {
        pointerSend("type:move\ndx:\(Int(dx.rounded()))\ndy:\(Int(dy.rounded()))\ndown:0\n\n")
    }

    override func clickPointer() {
        pointerSend("type:click\n\n")
    }

    override func scrollPointer(dy: Double) {
        pointerSend("type:scroll\ndx:0\ndy:\(Int(dy.rounded()))\n\n")
    }

    func channelList(_ completion: @escaping ([FavoriteChannel]) -> Void) {
        request("ssap://tv/getChannelList") { payload, _ in
            let list = payload["channelList"] as? [[String: Any]] ?? []
            completion(list.compactMap { item in
                guard let number = item["channelNumber"] as? String else { return nil }
                return FavoriteChannel(number: number, name: item["channelName"] as? String ?? "", channelID: item["channelId"] as? String)
            })
        }
    }

    /// Abre pelo ID do canal; sem ele, procura o número na lista de canais da TV.
    override func tune(_ channel: FavoriteChannel) {
        if let id = channel.channelID {
            request("ssap://tv/openChannel", ["channelId": id])
            return
        }
        request("ssap://tv/getChannelList") { [weak self] payload, ok in
            guard ok, let list = payload["channelList"] as? [[String: Any]],
                  let match = list.first(where: { ($0["channelNumber"] as? String) == channel.number }),
                  let id = match["channelId"] as? String else { return }
            self?.request("ssap://tv/openChannel", ["channelId": id])
        }
    }

    override func setVolume(_ value: Int) {
        volume = value
        request("ssap://audio/setVolume", ["volume": value])
    }

    override func setMuted(_ on: Bool) {
        muted = on
        request("ssap://audio/setMute", ["mute": on])
    }

    override func powerOff() {
        request("ssap://system/turnOff")
        nowPlaying = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.disconnect()
            self?.status = .offline(nil)
        }
    }

    override func launch(_ app: TVApp) {
        request("ssap://system.launcher/launch", ["id": app.id])
    }

    override func switchInput(_ input: TVInput) {
        if input.id == "livetv" {
            request("ssap://system.launcher/launch", ["id": "com.webos.app.livetv"])
        } else {
            request("ssap://tv/switchInput", ["inputId": input.id])
        }
    }

    /// Manifesto sem assinatura com as permissões que o app usa; a TV mostra o pedido uma vez.
    private static let registration: [String: Any] = [
        "forcePairing": false,
        "pairingType": "PROMPT",
        "manifest": [
            "manifestVersion": 1,
            "appVersion": "1.1",
            "permissions": [
                "APP_TO_APP", "CLOSE", "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
                "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_TEXT",
                "CONTROL_INPUT_TV", "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_POWER", "CONTROL_TV_SCREEN",
                "LAUNCH", "LAUNCH_WEBAPP", "READ_APP_STATUS", "READ_COUNTRY_INFO", "READ_CURRENT_CHANNEL",
                "READ_INPUT_DEVICE_LIST", "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_LGE_TV_INPUT_EVENTS",
                "READ_NETWORK_STATE", "READ_NOTIFICATIONS", "READ_POWER_STATE", "READ_RUNNING_APPS",
                "READ_SETTINGS", "READ_TV_CHANNEL_LIST", "READ_TV_CURRENT_TIME", "READ_UPDATE_INFO",
                "SEARCH", "TEST_OPEN", "TEST_PROTECTED", "TEST_SECURE", "UPDATE_FROM_REMOTE_APP",
                "WRITE_NOTIFICATION_ALERT", "WRITE_NOTIFICATION_TOAST", "WRITE_SETTINGS",
            ],
        ] as [String: Any],
    ]
}
