import AppKit
import Carbon.HIToolbox

/// Atalho global ⌥⌘R para abrir e fechar o painel. Usa a API de hot keys do Carbon,
/// que não precisa de permissão de Acessibilidade.
final class GlobalHotKey {
    private static var action: (() -> Void)?
    private var reference: EventHotKeyRef?

    init(keyCode: Int = kVK_ANSI_R, modifiers: Int = cmdKey | optionKey, action: @escaping () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4352_454D), id: 1) // "CREM"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &reference)
    }
}

/// Com o painel aberto, as teclas de volume, mudo e mídia do Mac vão para a TV em vez de
/// mudar o som do Mac. Interceptar essas teclas exige permissão de Acessibilidade, por isso
/// é opcional (menu ⋯).
final class MacKeys: ObservableObject {
    static let shared = MacKeys()

    enum Action { case volumeUp, volumeDown, mute, playPause, next, previous }

    /// Chamado na main thread; devolve se a TV recebeu (aí a tecla não chega ao Mac).
    var handler: ((Action) -> Bool)?
    /// Só intercepta enquanto o painel está aberto.
    var active = false {
        didSet { if active { startIfAllowed() } }
    }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "teclasDoMac")

    private var tap: CFMachPort?

    var trusted: Bool { AXIsProcessTrusted() }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "teclasDoMac")
        if on && !trusted {
            // Abre o pedido do macOS para liberar o app em Privacidade › Acessibilidade.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        if on { startIfAllowed() }
    }

    private func startIfAllowed() {
        guard enabled, trusted else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        // NX_SYSDEFINED (14): é o tipo de evento das teclas de volume e mídia.
        let mask = CGEventMask(1 << 14)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                let keys = Unmanaged<MacKeys>.fromOpaque(info!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = keys.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return keys.handle(event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Roda na main thread (o tap está no run loop principal).
    private func handle(_ event: CGEvent) -> Bool {
        guard active, enabled, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let code = Int32((ns.data1 & 0xFFFF_0000) >> 16)
        let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
        let action: Action
        switch code {
        case NX_KEYTYPE_SOUND_UP: action = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN: action = .volumeDown
        case NX_KEYTYPE_MUTE: action = .mute
        case NX_KEYTYPE_PLAY: action = .playPause
        case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST: action = .next
        case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND: action = .previous
        default: return false
        }
        // Engole também o "soltar" da tecla, mas só age no "apertar".
        if !down { return handler != nil }
        return handler?(action) ?? false
    }
}
