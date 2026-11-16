// Lecture de la luminosité de l'écran intégré du MacBook (lecture seule, jamais d'écriture).
//
// macOS n'offre pas d'API publique pour cela sur Apple Silicon. On utilise :
//
//  1. API PRIVÉE DisplayServices (méthode principale, celle qu'utilisent Centre de contrôle et
//     les utilitaires du même genre) :
//       /System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices
//       int32_t DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
//     Renvoie 0 en cas de succès et place dans *brightness la position du curseur système (0…1).
//     Le cadriciel est chargé dynamiquement (dlopen/dlsym) : si Apple le retire ou renomme la fonction,
//     l'app ne plante pas, elle passe simplement au repli. Autorisé car l'app n'est pas sandboxée.
//
//  2. Repli public IOKit : IODisplayGetFloatParameter(kIODisplayBrightnessKey) sur les services
//     « IODisplayConnect ». Fonctionne sur les Mac Intel ; sur Apple Silicon ce service n'existe
//     généralement pas et le repli renvoie nil.
//
// L'écran intégré est repéré par CGDisplayIsBuiltin parmi les écrans en ligne. Capot fermé
// (mode bureau), il n'est pas en ligne : la lecture renvoie nil.

import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

enum BuiltInBrightness {
    /// Signature C de DisplayServicesGetBrightness.
    private typealias GetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    /// Fonction privée résolue une seule fois (nil si le cadriciel ou le symbole manque).
    private static let displayServicesGetBrightness: GetBrightnessFunction? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        // Le cadriciel reste chargé pendant toute la vie de l'app : pas de dlclose.
        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightnessFunction.self)
    }()

    /// Identifiant de l'écran intégré s'il est en ligne (capot ouvert).
    static var displayID: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Luminosité actuelle de l'écran intégré (0…1), nil si inconnue ou écran éteint/fermé.
    static func read() -> Double? {
        guard let id = displayID else { return nil }
        if let get = displayServicesGetBrightness {
            var value: Float = 0
            if get(id, &value) == 0, value.isFinite {
                return Double(min(1, max(0, value)))
            }
        }
        return readWithIOKit()
    }

    /// Repli IOKit public (Mac Intel surtout).
    private static func readWithIOKit() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            var value: Float = 0
            let status = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value)
            IOObjectRelease(service)
            if status == kIOReturnSuccess, value.isFinite {
                return Double(min(1, max(0, value)))
            }
        }
        return nil
    }
}
