import AppKit
import Combine
import Foundation
import Network

/// As TVs conhecidas e a sessão da que está selecionada.
///
/// Para continuar funcionando sozinho:
/// - a TV é identificada pelo UUID e pelo MAC, não pelo IP; se ela some do IP salvo,
///   o app procura de novo (SSDP e, se precisar, a tabela ARP pelo MAC) e atualiza o IP;
/// - reconecta quando o Mac acorda, quando a rede volta ou muda, e a cada 30 s enquanto
///   a TV estiver desligada (para perceber quando alguém liga pelo controle físico);
/// - o pareamento fica salvo em disco e o app abre ao iniciar sessão.
final class RemoteStore: ObservableObject {
    @Published private(set) var devices: [TVDevice] = []
    @Published private(set) var session: TVSession?
    @Published private(set) var scanning = false

    private var statusWatch: AnyCancellable?
    private var lastRecovery = Date.distantPast
    private let pathMonitor = NWPathMonitor()
    private var lastNetwork: String?
    private var retryTimer: Timer?

    /// `autoConnect: false` nos modos de terminal, para o app não disputar a TV com o teste.
    init(autoConnect: Bool = true) {
        guard autoConnect else { return }
        let saved = DeviceStorage.load()
        devices = saved.devices
        if let device = devices.first(where: { $0.id == saved.selectedID }) ?? devices.first {
            activate(device)
        }
        // Procura sempre ao abrir: acha TVs novas e atualiza IPs que o roteador trocou.
        scan()
        LoginItem.enableOnFirstRun()
        watchSystem()
    }

    func select(_ device: TVDevice) {
        guard device.id != session?.device.id else { return }
        session?.disconnect()
        activate(device)
        persist()
    }

    /// Ao abrir o painel: conecta se a TV não estiver conectada, ou atualiza o que está na tela.
    func wakeUpConnection() {
        guard let session else { return }
        if session.status.isConnected {
            (session as? SamsungSession)?.refreshApps()
        } else if session.status != .pairing {
            session.connect()
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await Discovery.run()
            await MainActor.run {
                self.merge(found)
                self.scanning = false
            }
        }
    }

    private func activate(_ device: TVDevice) {
        let session = TVSession.make(for: device)
        session.onDeviceChange = { [weak self] in self?.update($0) }
        statusWatch = session.$status.removeDuplicates().sink { [weak self] status in
            if case .offline = status { self?.recoverAddress() }
        }
        self.session = session
        session.connect()
    }

    private func update(_ device: TVDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        persist()
    }

    private func merge(_ found: [TVDevice]) {
        for var tv in found {
            if let index = devices.firstIndex(where: { $0.id == tv.id || ($0.host == tv.host && $0.brand == tv.brand) }) {
                tv.token = devices[index].token
                tv.mac = tv.mac ?? devices[index].mac
                devices[index] = tv
                if let session, session.device.id == tv.id {
                    session.device.mac = tv.mac
                    session.device.name = tv.name
                    moveSession(to: tv.host)
                }
            } else {
                devices.append(tv)
            }
        }
        // O SSDP não achou a TV atual e ela não responde no IP salvo: varre a sub-rede.
        if let session, !session.status.isConnected, !found.contains(where: { $0.id == session.device.id }) {
            sweep(for: session)
        }
        if session == nil, let first = devices.first { activate(first) }
        persist()
    }

    private func sweep(for session: TVSession) {
        let device = session.device
        let known = Set(devices.filter { $0.id != device.id }.map(\.host) + [device.host])
        Task {
            guard let host = await Discovery.sweep(for: device, excluding: known) else { return }
            await MainActor.run {
                guard self.session === session else { return }
                self.moveSession(to: host)
                self.update(session.device)
            }
        }
    }

    /// A TV mudou de IP: atualiza e reconecta no endereço novo.
    private func moveSession(to host: String) {
        guard let session, session.device.host != host else { return }
        session.device.host = host
        if !session.status.isConnected { session.reconnect() }
    }

    /// A TV não respondeu no IP salvo: procura de novo (o roteador pode ter trocado o IP).
    private func recoverAddress() {
        guard Date().timeIntervalSince(lastRecovery) > 60 else { return }
        lastRecovery = Date()
        scan()
    }

    private func persist() {
        DeviceStorage.save(.init(devices: devices, selectedID: session?.device.id))
    }

    // MARK: Rede, sono e novas tentativas

    private func watchSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Depois de dormir o socket antigo pode estar morto sem avisar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.networkCameBack() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let network = path.status == .satisfied
                ? path.availableInterfaces.map(\.name).joined(separator: ",")
                : "sem rede"
            DispatchQueue.main.async { self?.networkChanged(to: network) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.retryIfOff()
        }
    }

    private func networkChanged(to network: String) {
        defer { lastNetwork = network }
        // Ao ligar o Mac o app pode abrir antes do Wi-Fi: quando a rede aparece, tenta de novo.
        guard let lastNetwork, network != lastNetwork, network != "sem rede" else { return }
        networkCameBack()
    }

    private func networkCameBack() {
        lastRecovery = .distantPast
        session?.reconnect()
        scan()
    }

    private func retryIfOff() {
        guard let session, !session.waking else { return }
        switch session.status {
        case .offline, .idle, .standby:
            session.connect()
        case .connected:
            (session as? SamsungSession)?.refreshPowerState()
            (session as? SamsungSession)?.refreshApps()
        default:
            break
        }
    }
}
