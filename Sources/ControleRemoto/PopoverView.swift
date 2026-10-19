import ServiceManagement
import SwiftUI

/// Paleta do painel: azul-marinho, sempre escuro, como o controle do tweet.
enum Theme {
    static let backgroundTop = Color(red: 0.08, green: 0.20, blue: 0.52)
    static let backgroundBottom = Color(red: 0.05, green: 0.14, blue: 0.40)
    static let surface = Color(red: 0.03, green: 0.09, blue: 0.28).opacity(0.78)
    static let surfacePressed = Color(red: 0.02, green: 0.06, blue: 0.20)
    static let track = Color(red: 0.02, green: 0.07, blue: 0.22)
    static let accent = Color(red: 0.27, green: 0.55, blue: 1.0)
    static let peach = Color(red: 0.98, green: 0.72, blue: 0.50)
    static let secondary = Color(red: 0.62, green: 0.70, blue: 0.86)
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.27)
    static let green = Color(red: 0.32, green: 0.86, blue: 0.47)
    static let hairline = Color.white.opacity(0.08)

    static var background: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
    }

    static func color(for status: ConnectionStatus) -> Color {
        switch status {
        case .connected: green
        case .connecting, .pairing: amber
        case .denied: Color(red: 1, green: 0.42, blue: 0.42)
        default: secondary.opacity(0.6)
        }
    }
}

enum Panel: String, CaseIterable, Identifiable {
    case input, apps, dpad, more

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .input: "rectangle.on.rectangle"
        case .apps: "play.rectangle"
        case .dpad: "dpad"
        case .more: "ellipsis"
        }
    }

    var caption: String {
        switch self {
        case .input: "Fonte"
        case .apps: "Apps"
        case .dpad: "Navegar"
        case .more: "Teclas"
        }
    }

    var title: String {
        switch self {
        case .input: "Entrada"
        case .apps: "Abrir"
        case .dpad: "Setas"
        case .more: "Mais"
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: RemoteStore

    var body: some View {
        Group {
            if let session = store.session {
                RemoteView(session: session, panel: nil).id(session.device.id)
            } else {
                EmptyStateView()
            }
        }
        .frame(width: 320)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }
}

/// Estado da tela. (Classe só para viver num @StateObject: o @State é uma macro que exige o Xcode.)
final class RemoteUIState: ObservableObject {
    @Published var panel: Panel?
    @Published var dragVolume: Double?
    var lastVolumeSent = Date.distantPast
    /// Aba Setas da LG mostrando o touchpad em vez das setas.
    @Published var pointerMode = false
    @Published var newFavoriteNumber = ""
    @Published var newFavoriteName = ""

    init(panel: Panel?) {
        self.panel = panel
    }
}

struct RemoteView: View {
    @EnvironmentObject var store: RemoteStore
    @ObservedObject var session: TVSession
    /// Falso nos snapshots, para as TVs de exemplo não tentarem conectar.
    var autoConnect = true
    @StateObject private var ui: RemoteUIState
    /// Onde está o foco do teclado: no controle (atalhos valem) ou num campo de texto.
    @FocusState private var focus: FocusTarget?

    enum FocusTarget: Hashable {
        case remote, favoriteNumber, favoriteName
    }

    init(session: TVSession, panel: Panel?, autoConnect: Bool = true, pointerMode: Bool = false) {
        self.session = session
        self.autoConnect = autoConnect
        let ui = RemoteUIState(panel: panel)
        ui.pointerMode = pointerMode
        _ui = StateObject(wrappedValue: ui)
    }

    private var panel: Panel? {
        get { ui.panel }
        nonmutating set { ui.panel = newValue }
    }

    private var dragVolume: Double? {
        get { ui.dragVolume }
        nonmutating set { ui.dragVolume = newValue }
    }

    private var connected: Bool { session.status.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScreenView(session: session)
            volume
            tiles
            if let panel {
                panelView(panel)
                    .disabled(!connected)
                    .transition(.opacity)
            }
            Theme.hairline.frame(height: 1)
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .remote)
        .onKeyPress(phases: [.down, .repeat]) { handleKey($0) }
        .onAppear {
            focus = .remote
            if autoConnect && !connected && !session.waking { store.wakeUpConnection() }
        }
        .animation(.snappy(duration: 0.2), value: panel)
    }

    // MARK: Cabeçalho

    private var sourceLabel: String {
        guard connected else { return session.device.brand.label }
        guard let now = session.nowPlaying else { return session.device.brand.label }
        return now.subtitle == "APP" || now.subtitle == "ENTRADA" ? now.title : "TV ao vivo"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tv")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            Text(session.device.name)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            Circle()
                .fill(Theme.color(for: session.status))
                .frame(width: 6, height: 6)
            Spacer(minLength: 6)
            Text(sourceLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Button {
                session.togglePower()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(connected ? Color.white : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(connected ? Theme.accent : Theme.surface))
                    .shadow(color: Theme.accent.opacity(connected ? 0.7 : 0), radius: 10)
            }
            .buttonStyle(PressStyle())
            .help(connected ? "Desligar a TV" : "Ligar a TV")
        }
    }

    // MARK: Volume

    private var volumeText: String {
        if let dragVolume { return "\(Int(dragVolume))" }
        return session.volume.map(String.init) ?? "—"
    }

    private var volume: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if session.supportsAbsoluteVolume {
                        Text(volumeText)
                            .font(.system(size: 46, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    } else {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 30, weight: .semibold))
                    }
                    Text("VOL")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                MutePill(muted: session.supportsMuteState ? (session.muted ?? false) : nil) {
                    if session.supportsMuteState {
                        session.setMuted(!(session.muted ?? false))
                    } else {
                        session.press(.mute)
                    }
                }
            }
            if session.supportsAbsoluteVolume {
                HStack(spacing: 10) {
                    CircleButton(icon: "minus") { session.press(.volumeDown) }
                    VolumeSlider(value: dragVolume ?? Double(session.volume ?? 0)) { value in
                        dragVolume = value
                        // Manda no máximo ~8 vezes por segundo enquanto arrasta.
                        if Date().timeIntervalSince(ui.lastVolumeSent) > 0.12 {
                            session.setVolume(Int(value))
                            ui.lastVolumeSent = Date()
                        }
                    } onEnd: {
                        if let dragVolume { session.setVolume(Int(dragVolume)) }
                        dragVolume = nil
                    }
                    CircleButton(icon: "plus") { session.press(.volumeUp) }
                }
                HStack {
                    Text("0")
                    Spacer()
                    Text("100")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.leading, 47)
                .padding(.trailing, 44)
            } else {
                HStack(spacing: 10) {
                    WideButton(icon: "minus", title: "Baixar") { session.press(.volumeDown) }
                    WideButton(icon: "plus", title: "Aumentar") { session.press(.volumeUp) }
                }
            }
        }
        .disabled(!connected)
        .opacity(connected ? 1 : 0.55)
    }

    // MARK: Atalhos

    private var tiles: some View {
        HStack(spacing: 7) {
            ForEach(Panel.allCases) { item in
                Button {
                    panel = panel == item ? nil : item
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                            .frame(height: 18)
                        Spacer(minLength: 10)
                        Text(item.caption)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                        Text(item.title)
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 58)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(SurfaceStyle(selected: panel == item, radius: 12))
            }
        }
    }

    @ViewBuilder private func panelView(_ panel: Panel) -> some View {
        switch panel {
        case .input: inputPanel
        case .apps: appsPanel
        case .dpad: dpadPanel
        case .more: morePanel
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputGrid
            favoritesSection
        }
    }

    private var inputGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(session.inputs) { input in
                Button {
                    session.switchInput(input)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: inputIcon(input))
                            .foregroundStyle(Theme.accent)
                        Text(input.label)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(SurfaceStyle())
                .opacity(input.connected ? 1 : 0.5)
            }
        }
    }

    private var favorites: [FavoriteChannel] { session.device.favorites ?? [] }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CANAIS FAVORITOS")
            if !favorites.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(favorites) { channel in
                        Button {
                            session.tune(channel)
                        } label: {
                            VStack(spacing: 2) {
                                Text(channel.number)
                                    .font(.system(size: 14, weight: .bold))
                                    .monospacedDigit()
                                Text(channel.name.isEmpty ? "Canal" : channel.name)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(SurfaceStyle())
                        .contextMenu {
                            Button("Remover dos favoritos") { session.removeFavorite(channel) }
                        }
                    }
                }
            }
            if let current = session.currentChannel, !favorites.contains(where: { $0.number == current.number }) {
                Button {
                    session.addFavorite(current)
                } label: {
                    Label("Salvar o canal atual (\(current.number) \(current.name))", systemImage: "star")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(SurfaceStyle())
            }
            HStack(spacing: 6) {
                TextField("Nº", text: $ui.newFavoriteNumber)
                    .focused($focus, equals: .favoriteNumber)
                    .frame(width: 44)
                TextField("Nome (opcional)", text: $ui.newFavoriteName)
                    .focused($focus, equals: .favoriteName)
                Button {
                    let number = ui.newFavoriteNumber.trimmingCharacters(in: .whitespaces)
                    guard !number.isEmpty else { return }
                    session.addFavorite(FavoriteChannel(number: number, name: ui.newFavoriteName.trimmingCharacters(in: .whitespaces)))
                    ui.newFavoriteNumber = ""
                    ui.newFavoriteName = ""
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(SurfaceStyle(radius: 7))
                .disabled(ui.newFavoriteNumber.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            if favorites.isEmpty {
                Text(session.supportsPointer
                     ? "Na TV ao vivo, salve o canal atual ou digite o número."
                     : "Digite o número do canal da antena. Clique com o botão direito para remover.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary.opacity(0.8))
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.secondary)
    }

    private func inputIcon(_ input: TVInput) -> String {
        let id = input.id.lowercased()
        if id.contains("hdmi") { return "cable.connector.horizontal" }
        if id.contains("tv") { return "antenna.radiowaves.left.and.right" }
        if id.contains("source") { return "list.bullet" }
        return "rectangle.connected.to.line.below"
    }

    private var appsPanel: some View {
        Group {
            if session.apps.isEmpty {
                Text(connected ? "Carregando apps…" : "Conecte a TV para ver os apps")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(session.apps) { app in
                            Button {
                                session.launch(app)
                            } label: {
                                VStack(spacing: 5) {
                                    AppBadge(app: app)
                                    Text(app.title)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .padding(.horizontal, 4)
                            }
                            .buttonStyle(SurfaceStyle())
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: session.apps.count > 6 ? 196 : nil)
            }
        }
    }

    private var dpadPanel: some View {
        VStack(spacing: 12) {
            if session.supportsPointer {
                ModePicker(pointerMode: $ui.pointerMode)
            }
            if session.supportsPointer && ui.pointerMode {
                Touchpad(session: session)
            } else {
                dpad
            }
            HStack(spacing: 8) {
                KeyButton(title: "Voltar", icon: "arrow.uturn.backward") { session.press(.back) }
                KeyButton(title: "Início", icon: "house") { session.press(.home) }
                KeyButton(title: "Menu", icon: "gearshape") { session.press(.menu) }
                KeyButton(title: "Info", icon: "info.circle") { session.press(.info) }
            }
            Text(ui.pointerMode && session.supportsPointer
                 ? "Arraste para mover · toque para clicar · faixa à direita rola"
                 : "Setas e Enter do teclado também funcionam · ⌫ volta")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }

    private var dpad: some View {
        ZStack {
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 150, height: 150)
                VStack(spacing: 0) {
                    arrow("chevron.up", .up)
                    HStack(spacing: 0) {
                        arrow("chevron.left", .left)
                        Button {
                            session.press(.ok)
                        } label: {
                            Text("OK")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 54, height: 54)
                                .background(Circle().fill(Theme.accent))
                                .shadow(color: Theme.accent.opacity(0.6), radius: 8)
                        }
                        .buttonStyle(PressStyle())
                        arrow("chevron.right", .right)
                    }
                    arrow("chevron.down", .down)
                }
        }
    }

    private func arrow(_ icon: String, _ key: RemoteKey) -> some View {
        Button {
            session.press(key)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var morePanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                KeyButton(title: "Recuar", icon: "backward.fill") { session.press(.rewind) }
                KeyButton(title: "Tocar", icon: "play.fill") { session.press(.play) }
                KeyButton(title: "Pausar", icon: "pause.fill") { session.press(.pause) }
                KeyButton(title: "Avançar", icon: "forward.fill") { session.press(.fastForward) }
            }
            HStack(spacing: 8) {
                KeyButton(title: "CH −", icon: "chevron.down") { session.press(.channelDown) }
                KeyButton(title: "CH +", icon: "chevron.up") { session.press(.channelUp) }
                KeyButton(title: "Sair", icon: "xmark") { session.press(.exit) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, -1, 0, -2], id: \.self) { n in
                    if n >= 0 {
                        Button {
                            session.press(.digit(n))
                        } label: {
                            Text("\(n)")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(SurfaceStyle())
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
    }

    // MARK: Rodapé

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.color(for: session.status))
                .frame(width: 7, height: 7)
            Text(session.waking && !connected ? "Ligando…" : session.status.label)
                .font(.system(size: 12, weight: .semibold))
            Text("· \(session.device.host)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.amber)
            Spacer()
            Menu {
                ForEach(store.devices) { tv in
                    Button {
                        store.select(tv)
                    } label: {
                        if tv.id == session.device.id {
                            Label("\(tv.name) (\(tv.brand.label))", systemImage: "checkmark")
                        } else {
                            Text("\(tv.name) (\(tv.brand.label))")
                        }
                    }
                }
                Divider()
                Button(store.scanning ? "Procurando…" : "Procurar TVs") { store.scan() }
                    .disabled(store.scanning)
            } label: {
                Image(systemName: "tv")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(Theme.accent)
            .help("Trocar de TV")
            Menu {
                Button("Reconectar") { session.reconnect() }
                Button("Parear de novo com \(session.device.name)") { session.forgetPairing() }
                Toggle("Abrir ao iniciar sessão", isOn: LoginItem.binding)
                Toggle("Teclas de volume e mídia do Mac controlam a TV", isOn: Binding {
                    MacKeys.shared.enabled
                } set: {
                    MacKeys.shared.setEnabled($0)
                })
                Text("Abrir o painel: ⌥⌘R")
                Divider()
                Button("Sair do Controle Remoto") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(PressStyle())
            .help("Encerrar o Controle Remoto")
        }
    }

    // MARK: Teclado

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Num campo de texto as teclas são do texto (e o Enter confirma o campo), não atalhos.
        guard connected, focus == .remote || focus == nil else { return .ignored }
        let key: RemoteKey?
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .return: key = .ok
        case .delete: key = .back
        default:
            switch press.characters {
            case "+", "=": key = .volumeUp
            case "-": key = .volumeDown
            case "m": key = .mute
            case "h": key = .home
            default: key = Int(press.characters).map { .digit($0) }
            }
        }
        guard let key else { return .ignored }
        session.press(key)
        return .handled
    }
}

/// O desenho da TV com o que está passando, como no controle do tweet.
struct ScreenView: View {
    @ObservedObject var session: TVSession

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.27), Color(white: 0.12), Color(white: 0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(white: 0.08), lineWidth: 4)
                VStack(spacing: 5) { content }
                    .padding(.horizontal, 14)
                Circle()
                    .fill(session.status.isConnected ? Theme.green : Color(white: 0.25))
                    .frame(width: 3, height: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(7)
            }
            .frame(width: 196, height: 112)
            Rectangle()
                .fill(Color(white: 0.1))
                .frame(width: 16, height: 8)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(white: 0.12))
                .frame(width: 96, height: 6)
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        if session.waking && !session.status.isConnected && session.status != .pairing {
            ProgressView().controlSize(.small)
            caption("LIGANDO")
        } else {
            switch session.status {
            case .connected:
                if let now = session.nowPlaying {
                    Text(now.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    caption(now.subtitle)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.white.opacity(0.8))
                    caption("CONECTADA")
                }
            case .pairing:
                Image(systemName: "hand.tap")
                    .foregroundStyle(.white.opacity(0.85))
                Text("Aceite o pedido\nna tela da TV")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            case .connecting, .idle:
                ProgressView().controlSize(.small)
                caption("CONECTANDO")
            case .standby, .offline:
                Image(systemName: "power")
                    .foregroundStyle(.white.opacity(0.4))
                caption("DESLIGADA")
            case .denied:
                Image(systemName: "xmark.octagon")
                    .foregroundStyle(.white.opacity(0.8))
                Text("Acesso negado na TV.\nUse Parear de novo.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Color(white: 0.6))
            .lineLimit(1)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: RemoteStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tv")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)
            Text(store.scanning ? "Procurando TVs na rede…" : "Nenhuma TV encontrada")
                .font(.headline)
            Text("TVs Samsung (Tizen) e LG (webOS) ligadas na mesma rede aparecem aqui.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            if store.scanning {
                ProgressView().controlSize(.small)
            } else {
                Button("Procurar de novo") { store.scan() }
            }
            Button("Sair") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Peças

struct SurfaceStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return configuration.label
            .background(shape.fill(configuration.isPressed ? Theme.surfacePressed : Theme.surface))
            .overlay(shape.strokeBorder(selected ? Theme.accent : Color.white.opacity(0.04), lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
    }
}

/// Seletor "Setas | Touchpad" da LG.
struct ModePicker: View {
    @Binding var pointerMode: Bool

    var body: some View {
        HStack(spacing: 4) {
            option("Setas", icon: "dpad", selected: !pointerMode) { pointerMode = false }
            option("Touchpad", icon: "hand.point.up.left", selected: pointerMode) { pointerMode = true }
        }
        .padding(3)
        .background(Capsule().fill(Theme.surface))
    }

    private func option(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Theme.accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Guarda a última posição do arraste. (Classe para viver num @StateObject; @State é macro.)
final class DragTracker: ObservableObject {
    var last: CGSize = .zero
    var moved = false
}

/// Touchpad para o cursor da LG (como o Magic Remote): arrastar move, tocar clica.
struct Touchpad: View {
    let session: TVSession
    @StateObject private var drag = DragTracker()
    @StateObject private var scroll = DragTracker()

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.secondary.opacity(0.35))
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let dx = value.translation.width - drag.last.width
                            let dy = value.translation.height - drag.last.height
                            drag.last = value.translation
                            if abs(value.translation.width) + abs(value.translation.height) > 3 { drag.moved = true }
                            if dx != 0 || dy != 0 { session.movePointer(dx: dx * 1.8, dy: dy * 1.8) }
                        }
                        .onEnded { _ in
                            if !drag.moved { session.clickPointer() }
                            drag.last = .zero
                            drag.moved = false
                        }
                )
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
                .frame(width: 30)
                .overlay(
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary.opacity(0.6))
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let dy = value.translation.height - scroll.last.height
                            scroll.last = value.translation
                            if abs(dy) >= 1 { session.scrollPointer(dy: dy) }
                        }
                        .onEnded { _ in scroll.last = .zero }
                )
        }
        .frame(height: 160)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct KeyButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 14)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(SurfaceStyle())
    }
}

struct WideButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(SurfaceStyle(radius: 18))
    }
}

struct CircleButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.surface))
        }
        .buttonStyle(PressStyle())
    }
}

/// Pílula "Mudo" com chave; sem estado (Samsung) vira só um botão.
struct MutePill: View {
    let muted: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                Text("Mudo")
                    .font(.system(size: 13, weight: .medium))
                if let muted {
                    ZStack(alignment: muted ? .trailing : .leading) {
                        Capsule()
                            .fill(muted ? Theme.accent : Color.white.opacity(0.14))
                        Circle()
                            .fill(.white)
                            .padding(2)
                    }
                    .frame(width: 34, height: 20)
                    .animation(.snappy(duration: 0.18), value: muted)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, muted == nil ? 12 : 6)
            .frame(height: 32)
            .background(Capsule().fill(Theme.surface))
        }
        .buttonStyle(PressStyle())
    }
}

/// Slider com o trecho preenchido em degradê azul → pêssego, como no tweet.
struct VolumeSlider: View {
    let value: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    private let knob: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - knob, 1)
            let x = travel * min(max(value, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                    .frame(height: 6)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.peach], startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + knob / 2, height: 6)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = min(max((drag.location.x - knob / 2) / travel, 0), 1)
                        onChange((fraction * 100).rounded())
                    }
                    .onEnded { _ in onEnd() }
            )
        }
        .frame(height: 28)
    }
}

/// Ícone do app; enquanto não carrega (ou se não achar), a inicial com uma cor fixa por nome.
struct AppBadge: View {
    let app: TVApp
    @ObservedObject private var icons = IconStore.shared

    private var color: Color {
        let seed = app.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(seed % 360) / 360, saturation: 0.55, brightness: 0.8)
    }

    var body: some View {
        Group {
            if let image = icons.images[app.title] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(color.gradient)
                    .overlay(
                        Text(String(app.title.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { icons.load(app) }
    }
}

enum LoginItem {
    static var binding: Binding<Bool> {
        Binding {
            SMAppService.mainApp.status == .enabled
        } set: { on in
            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    /// Na primeira vez que o app roda instalado, ele se coloca para abrir ao iniciar sessão,
    /// assim o controle continua lá depois de reiniciar o Mac. Dá para desligar no menu ⋯.
    static func enableOnFirstRun() {
        let key = "abrirAoIniciarConfigurado"
        guard Bundle.main.bundleURL.pathExtension == "app", !UserDefaults.standard.bool(forKey: key) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
    }
}
