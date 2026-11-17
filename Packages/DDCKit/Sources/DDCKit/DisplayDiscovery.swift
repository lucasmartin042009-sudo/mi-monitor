// Détection des écrans externes et association de chaque IOAVService au bon écran (Apple Silicon).
//
// Principe (même idée que MonitorControl) : on parcourt le registre IOKit dans l'ordre.
// Chaque framebuffer (IOMobileFramebufferShim / AppleCLCD2) porte les attributs EDID de son écran ;
// le DCPAVServiceProxy « External » qui le suit dans l'arbre est le bus DDC de ce même écran.
// On rapproche ensuite ces attributs (fabricant, produit, n° de série) d'un CGDirectDisplayID.

import CIOAVService
import CoreGraphics
import Foundation
import IOKit

/// Transport I2C réel, via les fonctions privées IOAVService.
public final class IOAVTransport: I2CTransport, @unchecked Sendable {
    private let service: IOAVService
    /// Adresse I2C 7 bits du DDC/CI.
    private let chip: UInt32 = 0x37

    init(service: IOAVService) { self.service = service }

    public func write(_ bytes: [UInt8]) -> Bool {
        var buf = bytes
        return IOAVServiceWriteI2C(service, chip, UInt32(DDCPacket.hostAddress), &buf, UInt32(buf.count)) == kIOReturnSuccess
    }

    public func read(count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        let r = IOAVServiceReadI2C(service, chip, UInt32(DDCPacket.hostAddress), &buf, UInt32(count))
        return r == kIOReturnSuccess ? buf : nil
    }
}

/// Identité EDID d'un écran, telle que publiée par le framebuffer.
public struct DisplayIdentity: Sendable, Equatable, CustomStringConvertible {
    public var productName: String?
    public var manufacturer: String?
    public var vendorID: UInt32?
    public var productID: UInt32?
    public var serialNumber: UInt32?
    public var alphanumericSerial: String?
    public var edidUUID: String?

    public init(productName: String? = nil, manufacturer: String? = nil, vendorID: UInt32? = nil,
                productID: UInt32? = nil, serialNumber: UInt32? = nil, alphanumericSerial: String? = nil,
                edidUUID: String? = nil) {
        self.productName = productName
        self.manufacturer = manufacturer
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.alphanumericSerial = alphanumericSerial
        self.edidUUID = edidUUID
    }

    public var description: String {
        var parts = [productName ?? "écran inconnu"]
        if let manufacturer { parts.append("fabricant \(manufacturer)") }
        if let vendorID, let productID { parts.append(String(format: "id %04X:%04X", vendorID, productID)) }
        if let alphanumericSerial { parts.append("série \(alphanumericSerial)") }
        return parts.joined(separator: ", ")
    }
}

/// Un écran externe pilotable en DDC.
public struct ExternalDisplay: Sendable {
    public let identity: DisplayIdentity
    /// Identifiant CoreGraphics de l'écran (nil si non rapproché).
    public let displayID: CGDirectDisplayID?
    public let device: DDCDevice

    /// Public pour les tests de l'app (écrans simulés) ; la détection réelle passe par DisplayDiscovery.
    public init(identity: DisplayIdentity, displayID: CGDirectDisplayID?, device: DDCDevice) {
        self.identity = identity
        self.displayID = displayID
        self.device = device
    }

    /// Nom lisible : celui de l'EDID, sinon celui de macOS.
    public var name: String { identity.productName ?? "Écran \(displayID.map(String.init) ?? "?")" }
}

public enum DisplayDiscovery {
    /// Liste les écrans externes ayant un service DDC sur Apple Silicon.
    public static func externalDisplays() -> [ExternalDisplay] {
        let pairs = servicePairs()
        let onlineIDs = onlineDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
        var used = Set<CGDirectDisplayID>()

        return pairs.map { identity, service in
            // Rapprochement par fabricant + produit (+ n° de série s'il est publié des deux côtés).
            let match = onlineIDs.first { id in
                guard !used.contains(id) else { return false }
                guard let v = identity.vendorID, let p = identity.productID,
                      CGDisplayVendorNumber(id) == v, CGDisplayModelNumber(id) == p else { return false }
                if let s = identity.serialNumber, s != 0, CGDisplaySerialNumber(id) != 0 {
                    return CGDisplaySerialNumber(id) == s
                }
                return true
            }
            // Repli : s'il n'y a qu'un écran externe et qu'un seul service, ils vont ensemble.
            let id = match ?? ((pairs.count == 1 && onlineIDs.count == 1) ? onlineIDs.first : nil)
            if let id { used.insert(id) }
            return ExternalDisplay(identity: identity, displayID: id,
                                   device: DDCDevice(transport: IOAVTransport(service: service)))
        }
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Parcourt le registre et renvoie les couples (identité EDID, IOAVService externe).
    static func servicePairs() -> [(DisplayIdentity, IOAVService)] {
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [(DisplayIdentity, IOAVService)] = []
        var pendingIdentity: DisplayIdentity?

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuf)
            let name = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                // Un framebuffer sans EDID (écran interne ou port vide) remet l'état à zéro.
                pendingIdentity = identity(of: entry)
            } else if name == "DCPAVServiceProxy" {
                let location = property(entry, "Location") as? String
                guard location == "External", let identity = pendingIdentity else { continue }
                if let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    result.append((identity, service))
                }
                pendingIdentity = nil
            }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Extrait l'identité EDID d'un framebuffer ; nil s'il n'y a pas d'écran externe derrière.
    private static func identity(of entry: io_registry_entry_t) -> DisplayIdentity? {
        guard let attrs = property(entry, "DisplayAttributes") as? [String: Any],
              let product = attrs["ProductAttributes"] as? [String: Any],
              product["ProductName"] != nil else { return nil }
        return DisplayIdentity(
            productName: product["ProductName"] as? String,
            manufacturer: product["ManufacturerID"] as? String,
            vendorID: (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
            productID: (product["ProductID"] as? NSNumber)?.uint32Value,
            serialNumber: (product["SerialNumber"] as? NSNumber)?.uint32Value,
            alphanumericSerial: product["AlphanumericSerialNumber"] as? String,
            edidUUID: property(entry, "EDID UUID") as? String
        )
    }
}
