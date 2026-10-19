import AppKit
import Combine
import SwiftUI

/// Ícone na barra de menus e o painel do controle, numa janela própria e opaca.
final class StatusController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: RemoteStore!
    private var statusItem: NSStatusItem!
    private var panel: RemotePanel!
    private var clickMonitor: Any?
    /// Topo do painel, logo abaixo do ícone: o painel cresce para baixo ao abrir uma seção.
    private var anchorTop: CGFloat = 0
    private var closedAt = Date.distantPast
    private var hotKey: GlobalHotKey?
    private var statusWatch: AnyCancellable?
    /// Play e pause são teclas separadas na TV; a tecla ⏯ do Mac alterna entre as duas.
    private var playing = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nos modos de terminal (--testar, --snapshot…) não há ícone nem conexão.
        let args = CommandLine.arguments
        guard args.contains("--abrir-painel") || !args.contains(where: { $0.hasPrefix("--") }) else { return }

        store = RemoteStore()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image(connected: false)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)

        let hosting = NSHostingController(rootView: PanelContent().environmentObject(store))
        hosting.sizingOptions = .preferredContentSize
        panel = RemotePanel(contentViewController: hosting)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }

        hotKey = GlobalHotKey { [weak self] in self?.toggle() }
        MacKeys.shared.handler = { [weak self] action in self?.handleMacKey(action) ?? false }

        // Ícone cheio quando a TV está conectada; vazado quando não.
        statusWatch = store.$session
            .compactMap { $0 }
            .map { session in session.$status.map { (session.device.name, $0) } }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name, status in
                self?.statusItem.button?.image = MenuBarIcon.image(connected: status.isConnected)
                self?.statusItem.button?.toolTip = "Controle Remoto — \(name): \(status.label) (⌥⌘R)"
            }

        // Para conferir o visual: abre o painel sozinho ao iniciar.
        if args.contains("--abrir-painel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.show() }
        }
    }

    @objc private func toggle() {
        // Clicar no ícone com o painel aberto tira o foco dele e já o fecha; não reabre.
        guard !panel.isVisible, Date().timeIntervalSince(closedAt) > 0.3 else {
            close()
            return
        }
        show()
    }

    private func show() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        anchorTop = buttonFrame.minY - 6
        panel.setFrameOrigin(NSPoint(x: x, y: anchorTop - size.height))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        store.wakeUpConnection()
        MacKeys.shared.active = true

        // Fecha ao clicar fora (em outro app ou na mesa).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func close() {
        guard panel.isVisible else { return }
        closedAt = Date()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        MacKeys.shared.active = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func handleMacKey(_ action: MacKeys.Action) -> Bool {
        guard let session = store.session, session.status.isConnected else { return false }
        switch action {
        case .volumeUp: session.press(.volumeUp)
        case .volumeDown: session.press(.volumeDown)
        case .mute:
            if session.supportsMuteState { session.setMuted(!(session.muted ?? false)) } else { session.press(.mute) }
        case .playPause:
            session.press(playing ? .pause : .play)
            playing.toggle()
        case .next: session.press(.fastForward)
        case .previous: session.press(.rewind)
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// O SwiftUI muda a altura ao abrir uma seção; mantém o topo grudado no ícone.
    func windowDidResize(_ notification: Notification) {
        guard panel.isVisible else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: anchorTop - panel.frame.height))
    }
}

/// Janela sem borda nem material: o fundo azul é desenhado pelo SwiftUI, opaco.
final class RemotePanel: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
    }

    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// Esc fecha o painel.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// O conteúdo do painel com os cantos arredondados e a borda fina.
struct PanelContent: View {
    var body: some View {
        PopoverView()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}
