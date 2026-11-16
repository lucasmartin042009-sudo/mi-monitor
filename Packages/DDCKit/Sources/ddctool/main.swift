// ddctool — outil de test de l'étape 0.
//
//   ddctool list                 écrans externes détectés et association IOAVService ↔ écran
//   ddctool caps [n]             chaîne de capacités (0xF3) et codes VCP annoncés
//   ddctool probe [n]            lit tous les codes intéressants (annoncés ou non)
//   ddctool get <code> [n]       lit un code VCP (hexadécimal, ex. 10)
//   ddctool set <code> <val> [n] écrit un code VCP puis relit la valeur
//
// [n] = numéro de l'écran dans `list` (0 par défaut).

import CoreGraphics
import DDCKit
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Erreur : \(message)\n".utf8))
    exit(1)
}

func hex(_ s: String) -> UInt8 {
    guard let v = UInt8(s.replacingOccurrences(of: "0x", with: ""), radix: 16) else { fail("code VCP invalide : \(s)") }
    return v
}

func display(at index: Int) -> ExternalDisplay {
    let all = DisplayDiscovery.externalDisplays()
    guard all.indices.contains(index) else { fail("aucun écran externe n° \(index) (\(all.count) détecté(s))") }
    return all[index]
}

/// Mesure la durée d'un appel DDC.
func timed<T>(_ body: () throws -> T) rethrows -> (T, Int) {
    let start = Date()
    let r = try body()
    return (r, Int(Date().timeIntervalSince(start) * 1000))
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "list"

switch command {
case "list":
    let all = DisplayDiscovery.externalDisplays()
    if all.isEmpty { print("Aucun écran externe avec service DDC trouvé.") }
    for (i, d) in all.enumerated() {
        print("[\(i)] \(d.identity)")
        print("    EDID UUID : \(d.identity.edidUUID ?? "—")")
        if let id = d.displayID {
            let b = CGDisplayBounds(id)
            print("    CGDirectDisplayID : \(id)  (\(Int(b.width))×\(Int(b.height)) pt à \(Int(b.minX)),\(Int(b.minY)))")
        } else {
            print("    CGDirectDisplayID : non rapproché")
        }
    }

case "caps":
    let d = display(at: args.count > 1 ? Int(args[1]) ?? 0 : 0)
    do {
        let (raw, ms) = try timed { try d.device.capabilitiesString() }
        print("Chaîne de capacités (\(raw.count) caractères, \(ms) ms) :\n\(raw)\n")
        let caps = Capabilities(parsing: raw)
        print("Modèle : \(caps.model ?? "—")  type : \(caps.type ?? "—")  MCCS : \(caps.mccsVersion ?? "—")")
        print("Codes VCP annoncés (\(caps.vcp.count)) :")
        for code in caps.supportedCodes {
            let values = caps.vcp[code] ?? []
            let list = values.isEmpty ? "" : "  valeurs : " + values.map { String(format: "%02X", $0) }.joined(separator: " ")
            print(String(format: "  0x%02X  %@", code, VCPCode.name(code)) + list)
        }
    } catch {
        fail("lecture des capacités : \(error)")
    }

case "probe":
    let d = display(at: args.count > 1 ? Int(args[1]) ?? 0 : 0)
    let codes: [UInt8] = [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62, 0x8D, 0xD6, 0x0C, 0x72, 0x87, 0xDC, 0xCA, 0xCC, 0xDF]
    for code in codes {
        let label = String(format: "0x%02X %-24@", code, VCPCode.name(code))
        do {
            let (v, ms) = try timed { try d.device.read(code) }
            print("\(label) courant \(v.current)  max \(v.maximum)  (\(ms) ms)")
        } catch {
            print("\(label) ✗ \(error)")
        }
    }

case "get":
    guard args.count >= 2 else { fail("usage : ddctool get <code> [n]") }
    let d = display(at: args.count > 2 ? Int(args[2]) ?? 0 : 0)
    let code = hex(args[1])
    do {
        let (v, ms) = try timed { try d.device.read(code) }
        print(String(format: "0x%02X %@ = %d (max %d) en %d ms", code, VCPCode.name(code), v.current, v.maximum, ms))
    } catch { fail("\(error)") }

case "set":
    guard args.count >= 3, let value = UInt16(args[2]) else { fail("usage : ddctool set <code> <valeur décimale> [n]") }
    let d = display(at: args.count > 3 ? Int(args[3]) ?? 0 : 0)
    let code = hex(args[1])
    do {
        let before = try d.device.read(code)
        let (_, ms) = try timed { try d.device.write(code, value: value) }
        // Relecture : certains réglages rendent l'écran muet un moment ; on mesure combien de temps.
        let start = Date()
        var after: VCPValue?
        while after == nil, Date().timeIntervalSince(start) < 5 {
            Thread.sleep(forTimeInterval: 0.1)
            after = try? d.device.read(code)
        }
        guard let after else { fail("pas de relecture possible pendant 5 s après l'écriture") }
        let silence = Int(Date().timeIntervalSince(start) * 1000)
        if silence > 500 { print("(écran muet ~\(silence) ms après l'écriture)") }
        print(String(format: "0x%02X %@ : avant %d → demandé %d → relu %d (écriture %d ms)",
                     code, VCPCode.name(code), before.current, value, after.current, ms))
        if after.current != value { print("⚠️ la valeur relue diffère de la valeur demandée") }
    } catch { fail("\(error)") }

case "sweep":
    // Simule un curseur : écritures successives sans relecture, puis relecture finale.
    // usage : ddctool sweep <code> <v1,v2,…> <écart ms> [n]
    guard args.count >= 4, let gap = Double(args[3]) else { fail("usage : ddctool sweep <code> <v1,v2,…> <écart ms> [n]") }
    let d = display(at: args.count > 4 ? Int(args[4]) ?? 0 : 0)
    let code = hex(args[1])
    let values = args[2].split(separator: ",").compactMap { UInt16($0) }
    var failures = 0
    let (_, ms) = timed {
        for v in values {
            do { try d.device.write(code, value: v) } catch { failures += 1 }
            Thread.sleep(forTimeInterval: gap / 1000)
        }
    }
    Thread.sleep(forTimeInterval: 1.0)
    let final = (try? d.device.read(code)).map { "\($0.current)" } ?? "illisible"
    print("\(values.count) écritures en \(ms) ms, \(failures) échec(s) ; attendu \(values.last ?? 0), relu \(final)")

case "seq":
    // Écritures enchaînées sur plusieurs codes, comme un profil : ddctool seq 14=4,10=15 <écart ms> [n]
    guard args.count >= 3, let gap = Double(args[2]) else { fail("usage : ddctool seq <code=val,…> <écart ms> [n]") }
    let d = display(at: args.count > 3 ? Int(args[3]) ?? 0 : 0)
    let steps = args[1].split(separator: ",").compactMap { pair -> (UInt8, UInt16)? in
        let kv = pair.split(separator: "=")
        guard kv.count == 2, let v = UInt16(kv[1]) else { return nil }
        return (hex(String(kv[0])), v)
    }
    for (code, v) in steps {
        do { try d.device.write(code, value: v) } catch { print(String(format: "0x%02X : échec %@", code, "\(error)")) }
        Thread.sleep(forTimeInterval: gap / 1000)
    }
    Thread.sleep(forTimeInterval: 1.0)
    for (code, v) in steps {
        let r = (try? d.device.read(code)).map { "\($0.current)" } ?? "illisible"
        print(String(format: "0x%02X demandé %d → relu %@", code, v, r))
    }

case "raw":
    // Débogage : envoie une requête Get VCP et affiche les octets bruts reçus.
    guard args.count >= 2 else { fail("usage : ddctool raw <code> [n]") }
    let d = display(at: args.count > 2 ? Int(args[2]) ?? 0 : 0)
    let frame = DDCPacket.getVCPRequest(hex(args[1]))
    // Variantes : nombre d'écritures consécutives et délai avant lecture.
    for (writes, delay) in [(1, 0.05), (2, 0.05), (1, 0.15), (2, 0.15), (1, 0.3)] {
        var ok = true
        for _ in 0..<writes { ok = d.device.transport.write(frame) && ok; Thread.sleep(forTimeInterval: 0.01) }
        Thread.sleep(forTimeInterval: delay)
        let r = d.device.transport.read(count: 12)
        print("\(writes) écriture(s), \(Int(delay * 1000)) ms, ok=\(ok) → "
              + (r.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "erreur"))
        Thread.sleep(forTimeInterval: 0.2)
    }

default:
    fail("commande inconnue « \(command) » (list, caps, probe, get, set)")
}
