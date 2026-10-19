import AppKit

/// Ícones dos apps, guardados em ~/Library/Application Support/ControleRemoto/icones.
/// A LG manda a URL do ícone na lista de apps. A Samsung não manda, então buscamos o ícone
/// oficial do app na App Store pelo nome (só o nome do app sai do Mac).
final class IconStore: ObservableObject {
    static let shared = IconStore()

    @Published private(set) var images: [String: NSImage] = [:]
    private var loading: Set<String> = []

    private let folder = DeviceStorage.url.deletingLastPathComponent().appendingPathComponent("icones")

    func load(_ app: TVApp) {
        let key = app.title
        guard images[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)

        let file = folder.appendingPathComponent(fileName(for: key))
        if let image = NSImage(contentsOf: file) {
            images[key] = image
            return
        }
        Task {
            let data = await Self.download(app)
            await MainActor.run {
                guard let data, let image = NSImage(data: data) else {
                    // Não achou: tenta de novo numa próxima abertura do app, não agora.
                    return
                }
                try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
                try? data.write(to: file)
                self.images[key] = image
            }
        }
    }

    private func fileName(for title: String) -> String {
        let safe = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(safe) + ".png"
    }

    private static func download(_ app: TVApp) async -> Data? {
        if let url = app.iconURL, let data = await HTTP.get(url.absoluteString, timeout: 4) {
            return data
        }
        return await appStoreIcon(for: app.title)
    }

    /// Procura na App Store brasileira e pega o primeiro resultado com o mesmo nome.
    private static func appStoreIcon(for title: String) async -> Data? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "country", value: "br"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components.url,
              let data = await HTTP.get(url.absoluteString, timeout: 6),
              let results = parseJSON(data)?["results"] as? [[String: Any]] else { return nil }

        let wanted = simplify(title)
        let match = results.first { simplify($0["trackName"] as? String ?? "") == wanted }
            ?? results.first { simplify($0["trackName"] as? String ?? "").contains(wanted) }
        guard let artwork = (match?["artworkUrl512"] ?? match?["artworkUrl100"]) as? String else { return nil }
        return await HTTP.get(artwork, timeout: 6)
    }

    private static func simplify(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == "+" }
    }
}
