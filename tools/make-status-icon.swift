// Ricava un'immagine template per la barra dei menu da un disegno in nero su
// fondo chiaro. Il PNG di partenza può non avere canale alpha (le esportazioni
// con lo sfondo "a scacchi" ne sono prive: la scacchiera è dipinta nei pixel),
// quindi l'opacità viene dedotta dalla luminanza.
//
//   swift tools/make-status-icon.swift <sorgente> <destinazione> [altezza px] [ingrossamento]
//
// L'ingrossamento (default 0.18, 0 per disattivarlo) compensa il fatto che a
// 19pt un tratto sottile finisce sotto il pixel e si legge grigio invece che
// pieno. Serve poco a un disegno già robusto, molto a uno a filo sottile.

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("sorgente non leggibile\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[2]
let targetHeight = args.count > 3 ? (Int(args[3]) ?? 36) : 36
let thickenFactor = args.count > 4 ? (Double(args[4]) ?? 0.18) : 0.18

/// Crea un buffer RGBA e ci disegna dentro: normalizza qualunque formato in
/// ingresso (con o senza alpha, indicizzato, CMYK) in qualcosa di prevedibile.
func rgbaBuffer(width: Int, height: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: width * 4, bitsPerPixel: 32)
}

let size = source.representations.first.map { ($0.pixelsWide, $0.pixelsHigh) }
    ?? (Int(source.size.width), Int(source.size.height))
let (w, h) = size
guard w > 0, h > 0, let full = rgbaBuffer(width: w, height: h) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: full)
source.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

// Tutto ciò che è più chiaro di questa soglia è sfondo. Sta sopra il grigio
// della scacchiera (0.96) così il motivo sparisce del tutto, e sotto il nero
// del tratto, di cui conserva i bordi antialiasati.
let backgroundCut = 0.90

guard let bytes = full.bitmapData else { exit(1) }
let rowBytes = full.bytesPerRow
for y in 0..<h {
    for x in 0..<w {
        let p = bytes + y * rowBytes + x * 4
        let existing = Double(p[3]) / 255
        let lum = (Double(p[0]) + Double(p[1]) + Double(p[2])) / (3 * 255)
        let derived = max(0, min(1, (backgroundCut - lum) / backgroundCut))
        // Se la sorgente ha già trasparenza vera, la rispetta; altrimenti la deduce.
        let alpha = existing < 0.99 ? existing : derived
        // Il colore non conta in un'immagine template: macOS la ricolora.
        p[0] = 0; p[1] = 0; p[2] = 0
        p[3] = UInt8((alpha * 255).rounded())
    }
}

// Il tratto originale è sottilissimo rispetto al disegno: ridotto a 18pt
// finirebbe sotto il pixel e si leggerebbe come una sbavatura grigia. Lo
// ingrossa con un filtro di massimo separabile (due passate monodimensionali:
// O(w·h·r) invece di O(w·h·r²)) prima di ridurre.
let dilate = Int((Double(h) / Double(targetHeight) * thickenFactor).rounded())
if dilate > 0 {
    var alpha = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { alpha[y * w + x] = (bytes + y * rowBytes + x * 4)[3] } }

    var pass = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            var m: UInt8 = 0
            for k in max(0, x - dilate)...min(w - 1, x + dilate) {
                m = max(m, alpha[y * w + k])
            }
            pass[y * w + x] = m
        }
    }
    for y in 0..<h {
        for x in 0..<w {
            var m: UInt8 = 0
            for k in max(0, y - dilate)...min(h - 1, y + dilate) {
                m = max(m, pass[k * w + x])
            }
            (bytes + y * rowBytes + x * 4)[3] = m
        }
    }
}

// Scala dopo aver estratto l'alpha: il ricampionamento sui bordi è più pulito.
let targetWidth = max(1, Int((Double(targetHeight) * Double(w) / Double(h)).rounded()))
guard let scaled = rgbaBuffer(width: targetWidth, height: targetHeight) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
NSGraphicsContext.current?.imageInterpolation = .high
full.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
          from: .zero, operation: .copy, fraction: 1,
          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
NSGraphicsContext.restoreGraphicsState()

guard let data = scaled.representation(using: .png, properties: [:]) else { exit(1) }
try? data.write(to: URL(fileURLWithPath: outPath))
print("  icona template \(targetWidth)x\(targetHeight) da \(w)x\(h), tratto ingrossato di \(dilate)px")
