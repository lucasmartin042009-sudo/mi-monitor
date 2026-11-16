// Tests de la couche DDC sans matériel : trames, sommes de contrôle, capacités, réessais.
import Testing
@testable import DDCKit

@Suite struct DDCPacketTests {
    @Test func getRequestFrame() {
        // 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10 = 0xAC (valeur de référence de la norme)
        #expect(DDCPacket.getVCPRequest(0x10) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func setRequestFrame() {
        let f = DDCPacket.setVCPRequest(0x10, value: 50)
        #expect(Array(f.prefix(5)) == [0x84, 0x03, 0x10, 0x00, 0x32])
        #expect(f.last == DDCPacket.checksum(seed: 0x6E ^ 0x51, f.dropLast()))
    }

    @Test func decodeGetReply() throws {
        var r: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2A]
        r.append(DDCPacket.checksum(seed: 0x50, r))
        let v = try DDCPacket.decodeGetVCPReply(r, expecting: 0x10)
        #expect(v == VCPValue(current: 42, maximum: 100))
    }

    @Test func rejectsBadChecksum() {
        let r: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2A, 0x00]
        #expect(throws: DDCPacket.DecodeError.badChecksum) { try DDCPacket.decodeGetVCPReply(r, expecting: 0x10) }
    }

    @Test func unsupportedCode() {
        var r: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x8D, 0x00, 0x00, 0x00, 0x00, 0x00]
        r.append(DDCPacket.checksum(seed: 0x50, r))
        #expect(throws: DDCPacket.DecodeError.unsupportedCode(0x8D)) { try DDCPacket.decodeGetVCPReply(r, expecting: 0x8D) }
    }

    @Test func parseCapabilities() {
        let caps = Capabilities(parsing: "(prot(monitor)type(LCD)model(Mi)cmds(01 02 03 F3)vcp(02 10 12 14(05 06 08) 60(0F 11 12) 62 8D(01 02))mccs_ver(2.2))")
        #expect(caps.model == "Mi")
        #expect(caps.mccsVersion == "2.2")
        #expect(caps.supportedCodes == [0x02, 0x10, 0x12, 0x14, 0x60, 0x62, 0x8D])
        #expect(caps.vcp[0x60] == [0x0F, 0x11, 0x12])
        #expect(caps.vcp[0x14] == [0x05, 0x06, 0x08])
    }

    @Test func parseGluedCodes() {
        #expect(Capabilities.parseVCPList("1012 60(0F11)").keys.sorted() == [0x10, 0x12, 0x60])
    }
}

/// Transport simulé : échoue N fois puis répond correctement.
final class FlakyTransport: I2CTransport, @unchecked Sendable {
    var failuresLeft: Int
    var writes: [[UInt8]] = []
    init(failures: Int) { failuresLeft = failures }
    func write(_ bytes: [UInt8]) -> Bool { writes.append(bytes); return true }
    func read(count: Int) -> [UInt8]? {
        if failuresLeft > 0 { failuresLeft -= 1; return [UInt8](repeating: 0, count: count) }
        var r: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x14]
        r.append(DDCPacket.checksum(seed: 0x50, r))
        return r
    }
}

@Suite struct DDCDeviceTests {
    @Test func retriesUntilValid() throws {
        let t = FlakyTransport(failures: 2)
        let d = DDCDevice(transport: t, sleep: { _ in })
        #expect(try d.read(0x10).current == 20)
        #expect(t.writes.count == 3 * 2) // 3 tentatives × 2 écritures
    }

    @Test func givesUpAfterAttempts() {
        let t = FlakyTransport(failures: 99)
        let d = DDCDevice(transport: t, sleep: { _ in })
        #expect(throws: DDCError.self) { try d.read(0x10) }
        #expect(t.writes.count == 4 * 2)
    }
}

@Suite struct QuietPeriodTests {
    /// Après une écriture « bruyante », la commande suivante attend la fin du silence de l'écran.
    @Test func waitsForQuietPeriod() throws {
        final class Clock: @unchecked Sendable { var slept: [Double] = [] }
        let clock = Clock()
        let t = FlakyTransport(failures: 0)
        var timing = DDCTiming()
        timing.quietAfterWrite = [0x14: 0.6]
        let d = DDCDevice(transport: t, timing: timing, sleep: { clock.slept.append($0) })
        try d.write(0x14, value: 4)
        try d.write(0x10, value: 15)
        // Une attente proche de 0,6 s doit précéder la seconde écriture.
        #expect(clock.slept.contains { $0 > 0.5 && $0 <= 0.6 })
    }
}
