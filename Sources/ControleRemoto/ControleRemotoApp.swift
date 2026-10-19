import Combine
import ServiceManagement
import AppKit

@main
enum ControleRemotoApp {
    /// AppKit puro: o painel é uma janela própria (StatusController). Sem cenas do SwiftUI,
    /// porque o MenuBarExtra deixa o fundo translúcido e a cena Settings abria uma janela vazia.
    static func main() {
        let app = NSApplication.shared
        let controller = StatusController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            DispatchQueue.main.async {
                Snapshot.renderAll(to: args[i + 1])
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--docs"), i + 1 < args.count {
            DispatchQueue.main.async {
                Snapshot.renderDocs(to: args[i + 1])
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--gerar-icone"), i + 1 < args.count {
            DispatchQueue.main.async {
                do {
                    try AppIconView.writeIconset(to: URL(fileURLWithPath: args[i + 1]))
                    exit(0)
                } catch {
                    print("Não consegui gerar o ícone: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }
        if let i = args.firstIndex(of: "--energia"), i + 2 < args.count {
            DispatchQueue.main.async { SelfTest.power(tv: args[i + 1], on: args[i + 2] == "ligar") }
        }
        if let i = args.firstIndex(of: "--canal"), i + 1 < args.count {
            let number = args.dropFirst(i + 2).first.flatMap { $0.hasPrefix("--") ? nil : $0 }
            DispatchQueue.main.async { SelfTest.channel(tv: args[i + 1], number: number) }
        }
        if let i = args.firstIndex(of: "--tecla") {
            let keys = args.dropFirst(i + 1).filter { !$0.hasPrefix("--") }
            DispatchQueue.main.async { SelfTest.sendKeys(keys) }
        }
        if args.contains("--status") {
            DispatchQueue.main.async { SelfTest.status() }
        }
        if args.contains("--descobrir") {
            DispatchQueue.main.async { SelfTest.discover() }
        }
        if let i = args.firstIndex(of: "--testar") {
            let seconds = args.dropFirst(i + 1).first.flatMap(Double.init) ?? 30
            DispatchQueue.main.async { SelfTest.run(seconds: seconds) }
        }
        app.run()
    }
}

/// Modos de terminal para testar sem abrir a barra de menus.
/// `--descobrir` lista as TVs da rede; `--testar [segundos]` conecta nas TVs salvas e
/// mostra o que cada uma responde (sem apertar nenhuma tecla); `--status` mostra as TVs
/// salvas e se o app abre ao iniciar sessão (rode pelo binário dentro do .app).
enum SelfTest {
    private static var sessions: [TVSession] = []
    private static var bag = Set<AnyCancellable>()

    static func status() {
        let login: String
        switch SMAppService.mainApp.status {
        case .enabled: login = "sim"
        case .requiresApproval: login = "aguardando aprovação em Ajustes › Geral › Itens de Início"
        case .notRegistered: login = "não"
        default: login = "não encontrado (rode pelo binário dentro do .app)"
        }
        print("Abre ao iniciar sessão: \(login)")
        for tv in DeviceStorage.load().devices {
            print("\(tv.brand.label) \(tv.name): \(tv.host) mac=\(tv.mac ?? "?") pareada=\(tv.token == nil ? "não" : "sim")")
        }
        exit(0)
    }

    /// `--tecla KEY_DTV KEY_TV …`: manda cada tecla para a Samsung salva, uma a cada 5 s,
    /// para descobrir qual código o modelo aceita. `aovivo` faz o mesmo que o botão TV ao vivo.
    static func sendKeys(_ keys: [String]) {
        guard let device = DeviceStorage.load().devices.first(where: { $0.brand == .samsung }),
              let session = TVSession.make(for: device) as? SamsungSession else {
            print("Nenhuma Samsung salva."); exit(1)
        }
        sessions.append(session)
        session.$status.removeDuplicates().sink { status in
            print("[\(device.name)] \(status.label)")
            guard status.isConnected else { return }
            for (index, key) in keys.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 5) {
                    print("→ \(key)")
                    if key == "aovivo" {
                        session.goToLiveTV()
                    } else if key.hasPrefix("app:") {
                        session.launchBySocket(String(key.dropFirst(4)))
                    } else {
                        session.send(key: key)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(keys.count) * 5) { exit(0) }
        }.store(in: &bag)
        session.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if !session.status.isConnected { print("Não conectou (a TV está ligada?)"); exit(1) }
        }
    }

    /// `--energia <parte do nome> ligar|desligar`: usa o mesmo caminho do botão de power do painel
    /// e mostra quanto tempo a TV levou para responder.
    static func power(tv name: String, on: Bool) {
        guard let device = DeviceStorage.load().devices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            print("Nenhuma TV com \"\(name)\" no nome."); exit(1)
        }
        let session = TVSession.make(for: device)
        sessions.append(session)
        let start = Date()
        var acted = false
        session.$status.removeDuplicates().sink { status in
            print(String(format: "[%@] %.1fs %@", device.name, Date().timeIntervalSince(start), status.label))
            if on && status.isConnected {
                print("Ligada e conectada."); exit(0)
            }
            if !on && status.isConnected && !acted {
                acted = true
                session.powerOff()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("Comando de desligar enviado."); exit(0) }
            }
        }.store(in: &bag)
        if on {
            session.powerOn()
            DispatchQueue.main.asyncAfter(deadline: .now() + 50) { print("Não ligou em 50 s."); exit(1) }
        } else {
            session.connect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("Não conectou para desligar."); exit(1) }
        }
    }

    /// `--canal <parte do nome> [número]`: sem número lista os canais (LG); com número, troca
    /// pelo mesmo caminho do favorito e mostra o canal que a TV informa depois.
    static func channel(tv name: String, number: String?) {
        guard let device = DeviceStorage.load().devices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            print("Nenhuma TV com \"\(name)\" no nome."); exit(1)
        }
        let session = TVSession.make(for: device)
        sessions.append(session)
        session.$currentChannel.compactMap { $0 }.removeDuplicates().sink {
            print("[\(device.name)] canal na tela: \($0.number) \($0.name)")
        }.store(in: &bag)
        var acted = false
        session.$status.sink { status in
            guard status.isConnected, !acted else { return }
            acted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let number {
                    print("→ favorito \(number)")
                    session.tune(FavoriteChannel(number: number, name: ""))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
                } else if let lg = session as? LGSession {
                    lg.channelList { list in
                        print(list.prefix(30).map { "\($0.number) \($0.name)" }.joined(separator: " | "))
                        exit(0)
                    }
                } else {
                    exit(0)
                }
            }
        }.store(in: &bag)
        session.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("Tempo esgotado."); exit(1) }
    }

    static func discover() {
        Task {
            let found = await Discovery.run()
            for tv in found {
                print("\(tv.brand.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(tv.host.padding(toLength: 15, withPad: " ", startingAt: 0)) \(tv.name)  mac=\(tv.mac ?? "?")")
            }
            if found.isEmpty { print("Nenhuma TV encontrada.") }
            if CommandLine.arguments.contains("--varrer") {
                // Testa o plano B: acha cada TV salva varrendo a sub-rede, sem usar o IP salvo.
                for tv in DeviceStorage.load().devices {
                    let ip = await Discovery.sweep(for: tv, excluding: [tv.host])
                    print("Varredura \(tv.name): \(ip ?? "não achou") (salvo: \(tv.host))")
                }
            }
            exit(0)
        }
    }

    static func run(seconds: Double) {
        Task {
            var saved = DeviceStorage.load()
            if saved.devices.isEmpty {
                saved.devices = await Discovery.run()
                DeviceStorage.save(saved)
            }
            let devices = saved.devices
            await MainActor.run {
                for device in devices { watch(device) }
                if devices.isEmpty { print("Nenhuma TV encontrada."); exit(1) }
            }
            try? await Task.sleep(for: .seconds(seconds))
            exit(0)
        }
    }

    private static func watch(_ device: TVDevice) {
        let tag = "[\(device.name)]"
        let session = TVSession.make(for: device)
        session.onDeviceChange = { changed in
            var saved = DeviceStorage.load()
            if let index = saved.devices.firstIndex(where: { $0.id == changed.id }) {
                saved.devices[index] = changed
                DeviceStorage.save(saved)
            }
            print("\(tag) pareamento salvo")
        }
        session.$status.removeDuplicates().sink { status in
            var line = "\(tag) \(status.label)"
            if case .offline(let reason?) = status { line += " (\(reason))" }
            if status == .pairing { line += " — aceite o pedido na tela da TV" }
            print(line)
        }.store(in: &bag)
        session.$volume.combineLatest(session.$muted).dropFirst().removeDuplicates { $0 == $1 }.sink { volume, muted in
            print("\(tag) volume \(volume.map(String.init) ?? "?")\(muted == true ? " (mudo)" : "")")
        }.store(in: &bag)
        session.$nowPlaying.compactMap { $0 }.removeDuplicates().sink {
            print("\(tag) na tela: \($0.title) · \($0.subtitle)")
        }.store(in: &bag)
        session.$apps.filter { !$0.isEmpty }.sink {
            print("\(tag) \($0.count) apps: \($0.prefix(8).map(\.title).joined(separator: ", "))…")
        }.store(in: &bag)
        session.$inputs.filter { !$0.isEmpty }.sink {
            print("\(tag) entradas: \($0.map(\.label).joined(separator: ", "))")
        }.store(in: &bag)
        sessions.append(session)
        session.connect()
    }
}
