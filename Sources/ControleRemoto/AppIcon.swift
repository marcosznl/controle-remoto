import AppKit
import SwiftUI

/// Ícone da barra de menus: a mesma silhueta do ícone do app (controle inclinado com o
/// direcional e dois botões). Contorno quando desconectado, preenchido quando conectado.
enum MenuBarIcon {
    static func image(connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 9, y: 9)
            context.rotate(by: 12 * .pi / 180)
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: NSRect(x: -4.4, y: -8, width: 8.8, height: 16), xRadius: 4.4, yRadius: 4.4)
            let dpad = NSRect(x: -2.9, y: -0.1, width: 5.8, height: 5.8)
            let buttons = [NSRect(x: -2.6, y: -4.6, width: 1.9, height: 1.9), NSRect(x: 0.7, y: -4.6, width: 1.9, height: 1.9)]
            if connected {
                body.fill()
                // Recorta o direcional e os botões (ficam transparentes no ícone "template").
                context.setBlendMode(.destinationOut)
                NSBezierPath(ovalIn: dpad).fill()
                buttons.forEach { NSBezierPath(ovalIn: $0).fill() }
                context.setBlendMode(.normal)
                NSBezierPath(ovalIn: dpad.insetBy(dx: 1.6, dy: 1.6)).fill()
            } else {
                body.lineWidth = 1.3
                body.stroke()
                let ring = NSBezierPath(ovalIn: dpad.insetBy(dx: 0.3, dy: 0.3))
                ring.lineWidth = 1.1
                ring.stroke()
                NSBezierPath(ovalIn: dpad.insetBy(dx: 1.9, dy: 1.9)).fill()
                buttons.forEach { NSBezierPath(ovalIn: $0.insetBy(dx: 0.1, dy: 0.1)).fill() }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Prévia ampliada sobre a barra clara e a escura (para o --snapshot).
    static func preview(to url: URL) {
        let scale: CGFloat = 8
        let size = NSSize(width: 2 * 30 * scale, height: 2 * 24 * scale)
        let output = NSImage(size: size, flipped: false) { _ in
            for (row, (background, ink)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.17, alpha: 1), NSColor.white)].enumerated() {
                background.setFill()
                NSRect(x: 0, y: CGFloat(row) * 24 * scale, width: size.width, height: 24 * scale).fill()
                for (column, connected) in [false, true].enumerated() {
                    let icon = image(connected: connected)
                    let tinted = NSImage(size: icon.size, flipped: false) { rect in
                        icon.draw(in: rect)
                        ink.set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: (CGFloat(column) * 30 + 6) * scale, y: (CGFloat(row) * 24 + 3) * scale,
                                           width: 18 * scale, height: 18 * scale))
                }
            }
            return true
        }
        if let tiff = output.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

/// O ícone do app, desenhado em código: um controle remoto claro sobre o azul-marinho do painel.
/// `ControleRemoto --gerar-icone <pasta.iconset>` grava os PNGs; scripts/make-icon.sh monta o .icns.
struct AppIconView: View {
    var body: some View {
        ZStack {
            // Grade de ícones do macOS: 824 pt de 1024, cantos de 185.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.30, blue: 0.70), Theme.backgroundBottom],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 12)

            remote
                .rotationEffect(.degrees(-12))
                .offset(y: 10)
        }
        .frame(width: 1024, height: 1024)
    }

    private var remote: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 150, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(red: 0.84, green: 0.88, blue: 0.97)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 300, height: 660)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 24)

            VStack(spacing: 44) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "power").font(.system(size: 24, weight: .bold)).foregroundStyle(.white))
                ZStack {
                    Circle()
                        .fill(Theme.backgroundBottom)
                        .frame(width: 210, height: 210)
                    ForEach(0..<4) { index in
                        Capsule()
                            .fill(.white.opacity(0.85))
                            .frame(width: 26, height: 8)
                            .offset(y: -78)
                            .rotationEffect(.degrees(Double(index) * 90))
                    }
                    Circle()
                        .fill(LinearGradient(colors: [Theme.accent, Color(red: 0.18, green: 0.42, blue: 0.92)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 96, height: 96)
                }
                HStack(spacing: 36) {
                    Circle().fill(Theme.backgroundBottom).frame(width: 56, height: 56)
                    Circle().fill(Theme.backgroundBottom).frame(width: 56, height: 56)
                }
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.peach], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 150, height: 20)
            }
            .padding(.top, 58)
        }
    }

    @MainActor
    static func writeIconset(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let pixels = points * scale
            let renderer = ImageRenderer(content: AppIconView())
            renderer.scale = CGFloat(pixels) / 1024
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try png.write(to: folder.appendingPathComponent(name))
        }
    }
}
