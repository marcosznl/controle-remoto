import AppKit
import SwiftUI

/// `ControleRemoto --snapshot <pasta>` salva PNGs do painel com TVs de exemplo e sai,
/// para conferir o visual sem abrir a barra de menus.
/// `ControleRemoto --docs <pasta>` gera as imagens do README (mesmas TVs de exemplo).
@MainActor
enum Snapshot {
    private static let lg = TVDevice(id: "lg", name: "TV do Quarto", brand: .lg, host: "192.168.1.21")
    private static let samsung = TVDevice(id: "samsung", name: "TV da Sala", brand: .samsung, host: "192.168.1.20")

    static func renderAll(to dir: String) {
        let out = folder(dir)
        let store = RemoteStore(autoConnect: false)
        MenuBarIcon.preview(to: out.appendingPathComponent("barra-de-menus.png"))

        // O painel é sempre escuro; o modo claro do sistema só confere que nada vaza.
        for (mode, appearance) in [("claro", NSAppearance.Name.aqua), ("escuro", .darkAqua)] {
            let cases: [(String, TVSession, Panel?)] = [
                ("lg-inicio", sample(lg), nil),
                ("lg-setas", sample(lg), .dpad),
                ("lg-apps", sample(lg), .apps),
                ("lg-entradas", sample(lg), .input),
                ("lg-touchpad", sample(lg), .dpad),
                ("samsung-mais", sample(samsung), .more),
                ("pareando", sample(samsung, status: .pairing), nil),
                ("desligada", sample(lg, status: .offline(nil)), nil),
            ]
            for (name, session, panel) in cases {
                save(panelView(session, panel, store, pointer: name.contains("touchpad")), appearance,
                     to: out.appendingPathComponent("\(name)-\(mode).png"))
            }
        }
    }

    static func renderDocs(to dir: String) {
        let out = folder(dir)
        let store = RemoteStore(autoConnect: false)
        save(HeroView(panel: panelView(sample(lg), nil, store, rounded: true)), .darkAqua, to: out.appendingPathComponent("painel.png"))
        let cases: [(String, TVSession, Panel?)] = [
            ("setas", sample(lg), .dpad),
            ("touchpad", sample(lg), .dpad),
            ("apps", sample(lg), .apps),
            ("entradas", sample(lg), .input),
            ("samsung", sample(samsung), .more),
            ("pareando", sample(samsung, status: .pairing), nil),
        ]
        for (name, session, panel) in cases {
            save(panelView(session, panel, store, pointer: name == "touchpad", rounded: true), .darkAqua,
                 to: out.appendingPathComponent("\(name).png"))
        }
        MenuBarIcon.preview(to: out.appendingPathComponent("barra-de-menus.png"))
        let icon = ImageRenderer(content: AppIconView())
        icon.scale = 0.25
        if let image = icon.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("icone.png"))
        }
    }

    private static func folder(_ dir: String) -> URL {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    private static func panelView(_ session: TVSession, _ panel: Panel?, _ store: RemoteStore,
                                  pointer: Bool = false, rounded: Bool = false) -> some View {
        RemoteView(session: session, panel: panel, autoConnect: false, pointerMode: pointer)
            .environmentObject(store)
            .frame(width: 320)
            .background(Theme.background)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: rounded ? 16 : 0, style: .continuous))
    }

    private static func sample(_ device: TVDevice, status: ConnectionStatus = .connected) -> TVSession {
        var device = device
        device.favorites = [FavoriteChannel(number: "4-1", name: "Globo HD"), FavoriteChannel(number: "11-1", name: "SBT HD"),
                            FavoriteChannel(number: "7-1", name: "Band HD")]
        let session = TVSession.make(for: device)
        session.status = status
        if device.brand == .lg {
            session.volume = 67
            session.muted = false
            session.nowPlaying = NowPlaying(title: "CH 4-1", subtitle: "GLOBO HD")
            session.currentChannel = FavoriteChannel(number: "13-1", name: "RecordTV HD")
            session.inputs = [TVInput(id: "livetv", label: "TV ao vivo"), TVInput(id: "HDMI_1", label: "HDMI 1"),
                              TVInput(id: "HDMI_2", label: "PlayStation 5"), TVInput(id: "HDMI_3", label: "HDMI 3", connected: false)]
        } else {
            session.nowPlaying = NowPlaying(title: "Netflix", subtitle: "APP")
        }
        session.apps = ["Apple TV", "Disney+", "Globoplay", "HBO Max", "Netflix", "Prime Video", "Twitch", "YouTube", "Apple Music"]
            .map { TVApp(id: $0, title: $0) }
        return session
    }

    private static func save(_ view: some View, _ appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Imagem de destaque do README: o painel aberto embaixo do ícone, numa barra de menus.
private struct HeroView<Panel: View>: View {
    let panel: Panel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.42, green: 0.66, blue: 0.96), Color(red: 0.10, green: 0.24, blue: 0.58)],
                           startPoint: .top, endPoint: .bottom)
            HStack(spacing: 16) {
                Image(nsImage: MenuBarIcon.image(connected: true))
                    .renderingMode(.template)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.28)))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "magnifyingglass")
                Text("Seg. 21:30")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: 30)
            .background(.white.opacity(0.14))
            panel
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                .padding(.top, 38)
                .padding(.trailing, 62)
        }
        .frame(width: 760, height: 590)
    }
}
