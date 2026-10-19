import Foundation
import SwiftUI

enum TVBrand: String, Codable {
    case samsung, lg

    var label: String { self == .samsung ? "Samsung" : "LG" }
}

/// Uma TV salva. O token é o que a TV devolve depois que você aceita o pareamento na tela dela.
struct TVDevice: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var brand: TVBrand
    var host: String
    /// MAC da interface que a TV está usando (é para ele que vai o Wake-on-LAN).
    var mac: String?
    /// MAC da outra interface (cabo ou Wi-Fi), que também recebe o Wake-on-LAN.
    var altMAC: String?
    var token: String?
    var favorites: [FavoriteChannel]?
}

/// Canal favorito. Na LG o `id` abre o canal direto; na Samsung o app digita o número.
struct FavoriteChannel: Codable, Hashable, Identifiable {
    var number: String
    var name: String
    var channelID: String?

    var id: String { number }
}

struct TVApp: Identifiable, Hashable {
    let id: String
    let title: String
    /// `app_type` da Samsung: 4 abre como app nativo, o resto por deep link.
    var kind = 2
    /// Ícone servido pela própria TV (a LG manda; a Samsung não).
    var iconURL: URL?
}

struct TVInput: Identifiable, Hashable {
    let id: String
    let label: String
    var connected = true
}

struct NowPlaying: Equatable {
    var title: String
    var subtitle: String
}

enum ConnectionStatus: Equatable {
    case idle, connecting, pairing, connected, standby, denied
    case offline(String?)

    var isConnected: Bool { self == .connected }

    var label: String {
        switch self {
        case .idle: "Desconectada"
        case .connecting: "Conectando…"
        case .pairing: "Aguardando a TV"
        case .connected: "Conectada"
        case .standby: "Em espera"
        case .denied: "Acesso negado"
        case .offline: "Desligada"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .pairing: .orange
        case .denied: .red
        default: .gray
        }
    }
}

enum RemoteKey: Hashable {
    case up, down, left, right, ok, back, home, menu, info, exit
    case play, pause, rewind, fastForward
    case channelUp, channelDown, volumeUp, volumeDown, mute
    case digit(Int)
}

/// As TVs ficam num JSON em ~/Library/Application Support/ControleRemoto, que o app
/// e o modo de teste pelo terminal (`--testar`) compartilham.
enum DeviceStorage {
    struct Saved: Codable {
        var devices: [TVDevice] = []
        var selectedID: String?
    }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ControleRemoto/tvs.json")
    }

    static func load() -> Saved {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return saved
    }

    static func save(_ saved: Saved) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(saved).write(to: url, options: .atomic)
    }
}

func parseJSON(_ text: String) -> [String: Any]? {
    parseJSON(Data(text.utf8))
}

func parseJSON(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

enum HTTP {
    static func get(_ address: String, timeout: TimeInterval = 2) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        let request = URLRequest(url: url, timeoutInterval: timeout)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func post(_ address: String, timeout: TimeInterval = 4) async -> Bool {
        guard let url = URL(string: address) else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
