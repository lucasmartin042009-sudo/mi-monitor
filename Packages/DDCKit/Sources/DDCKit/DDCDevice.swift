// Communication DDC/CI avec un écran : délais, réessais, lecture des capacités.
// Le transport I2C est abstrait (protocole I2CTransport) pour pouvoir tester sans matériel.

import Foundation

/// Accès brut au bus I2C de l'écran.
public protocol I2CTransport: AnyObject, Sendable {
    /// Écrit une trame complète. Renvoie false si le pilote signale une erreur.
    func write(_ bytes: [UInt8]) -> Bool
    /// Lit `count` octets. Renvoie nil si le pilote signale une erreur.
    func read(count: Int) -> [UInt8]?
}

/// Délais de la norme DDC/CI (l'écran a besoin de temps pour préparer sa réponse).
public struct DDCTiming: Sendable {
    /// Attente entre l'écriture d'une requête et la lecture de la réponse (norme : 40 ms).
    public var replyDelay: TimeInterval = 0.05
    /// Attente minimale après une écriture « Set VCP » avant la commande suivante (norme : 50 ms).
    public var postWriteDelay: TimeInterval = 0.05
    /// Attente entre deux tentatives après un échec.
    public var retryDelay: TimeInterval = 0.08
    /// Nombre d'écritures consécutives de chaque trame. Le Mi Monitor ignore une requête
    /// isolée (il renvoie un message nul « 6E 80 BE ») mais répond quand elle est envoyée deux fois.
    public var writeCycles: Int = 2
    /// Pause entre deux écritures consécutives.
    public var writeCycleGap: TimeInterval = 0.01
    /// Nombre total de tentatives par commande.
    public var attempts: Int = 4
    /// Silence de l'écran après l'écriture de certains codes : pendant ce délai il ignore
    /// TOUTE commande (lecture comme écriture, quel que soit le code). Propre à chaque modèle.
    public var quietAfterWrite: [UInt8: TimeInterval] = [:]

    public init() {}
}

public enum DDCError: Error, CustomStringConvertible {
    case writeFailed
    case readFailed
    case decode(DDCPacket.DecodeError)
    case noResponse(lastError: String)

    public var description: String {
        switch self {
        case .writeFailed: "écriture I2C refusée par le pilote"
        case .readFailed: "lecture I2C refusée par le pilote"
        case .decode(let e): e.description
        case .noResponse(let last): "pas de réponse valide de l'écran (\(last))"
        }
    }
}

/// Un écran joignable en DDC/CI. Les appels sont bloquants (bus lent) et sérialisés par un verrou :
/// à appeler hors du fil principal.
public final class DDCDevice: @unchecked Sendable {
    public let transport: I2CTransport
    public var timing: DDCTiming
    private let lock = NSLock()
    /// Instant de la dernière écriture, pour respecter le délai minimal entre commandes.
    private var lastWrite = Date.distantPast
    /// L'écran est « sourd » jusqu'à cet instant (cf. DDCTiming.quietAfterWrite).
    private var quietUntil = Date.distantPast
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(transport: I2CTransport, timing: DDCTiming = DDCTiming(),
                sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.transport = transport
        self.timing = timing
        self.sleep = sleep
    }

    /// Reprend l'heure de la dernière écriture et le silence en cours d'un autre périphérique
    /// du même écran (rattachement après un réveil) : un silence de ~820 ms commencé avec
    /// l'ancien accès doit encore être respecté par le nouveau.
    public func inheritPacing(from other: DDCDevice) {
        guard other !== self else { return }
        other.lock.lock()
        let (write, quiet) = (other.lastWrite, other.quietUntil)
        other.lock.unlock()
        lock.lock()
        lastWrite = max(lastWrite, write)
        quietUntil = max(quietUntil, quiet)
        lock.unlock()
    }

    // MARK: - Commandes

    /// Lit la valeur courante et le maximum d'un code VCP, avec réessais.
    public func read(_ code: UInt8) throws -> VCPValue {
        try withLock {
            try retrying { () throws -> VCPValue in
                let raw = try request(DDCPacket.getVCPRequest(code), replyLength: 11)
                do { return try DDCPacket.decodeGetVCPReply(raw, expecting: code) }
                catch let e as DDCPacket.DecodeError { throw DDCError.decode(e) }
            }
        }
    }

    /// Écrit une valeur. Le DDC ne confirme pas les écritures : l'appelant peut relire pour vérifier.
    public func write(_ code: UInt8, value: UInt16) throws {
        try withLock {
            try retrying { () throws in
                try send(DDCPacket.setVCPRequest(code, value: value))
                if let quiet = timing.quietAfterWrite[code] { quietUntil = lastWrite.addingTimeInterval(quiet) }
            }
        }
    }

    /// Lit la chaîne de capacités complète (commande 0xF3), fragment par fragment.
    public func capabilitiesString(maxLength: Int = 4096) throws -> String {
        try withLock {
            var data: [UInt8] = []
            while data.count < maxLength {
                let offset = UInt16(data.count)
                let chunk = try retrying { () throws -> [UInt8] in
                    let raw = try request(DDCPacket.capabilitiesRequest(offset: offset), replyLength: 38)
                    let decoded: (offset: UInt16, chunk: [UInt8])
                    do { decoded = try DDCPacket.decodeCapabilitiesReply(raw) }
                    catch let e as DDCPacket.DecodeError { throw DDCError.decode(e) }
                    // Un écran qui renvoie un autre décalage est désynchronisé : on réessaie.
                    guard decoded.offset == offset else {
                        throw DDCError.decode(.codeMismatch(expected: UInt8(offset & 0xFF), got: UInt8(decoded.offset & 0xFF)))
                    }
                    return decoded.chunk
                }
                if chunk.isEmpty { break }
                data += chunk
            }
            // Certains écrans terminent la chaîne par des octets nuls.
            return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: - Mécanique interne

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Attend le délai minimal après la dernière écriture, et la fin d'un éventuel silence de l'écran.
    private func waitSinceLastWrite() {
        let ready = max(lastWrite.addingTimeInterval(timing.postWriteDelay), quietUntil)
        let wait = ready.timeIntervalSinceNow
        if wait > 0 { sleep(wait) }
    }

    /// Écrit une trame `writeCycles` fois ; réussit si au moins une écriture est acceptée.
    private func send(_ frame: [UInt8]) throws {
        waitSinceLastWrite()
        var accepted = false
        for cycle in 0..<max(1, timing.writeCycles) {
            if cycle > 0 { sleep(timing.writeCycleGap) }
            if transport.write(frame) { accepted = true }
        }
        lastWrite = Date()
        if !accepted { throw DDCError.writeFailed }
    }

    /// Écrit une requête, attend, puis lit la réponse brute.
    private func request(_ frame: [UInt8], replyLength: Int) throws -> [UInt8] {
        try send(frame)
        sleep(timing.replyDelay)
        guard let raw = transport.read(count: replyLength) else { throw DDCError.readFailed }
        return raw
    }

    private func retrying<T>(_ body: () throws -> T) throws -> T {
        var last: DDCError = .noResponse(lastError: "aucune tentative")
        for attempt in 0..<max(1, timing.attempts) {
            if attempt > 0 { sleep(timing.retryDelay) }
            do { return try body() } catch let error as DDCError {
                // Un code non supporté est une réponse définitive : inutile d'insister.
                if case .decode(.unsupportedCode) = error { throw error }
                last = error
            }
        }
        throw DDCError.noResponse(lastError: last.description)
    }
}
