// Déclarations des fonctions privées d'IOKit utilisées pour le DDC/CI sur Apple Silicon.
// Ces symboles existent dans IOKit.framework mais ne sont pas publiés dans les en-têtes.
// Signatures reprises des projets open source MonitorControl et m1ddc (licence MIT).
#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

typedef CFTypeRef IOAVServiceRef;

/// Crée un objet IOAVService à partir d'un nœud DCPAVServiceProxy du registre IOKit.
extern IOAVServiceRef _Nullable IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator, io_service_t service);

/// Lit `outputBufferSize` octets sur le bus I2C de l'écran (adresse de puce 0x37 pour le DDC).
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef _Nonnull service, uint32_t chipAddress, uint32_t offset,
                                   void * _Nonnull outputBuffer, uint32_t outputBufferSize);

/// Écrit `inputBufferSize` octets sur le bus I2C de l'écran.
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef _Nonnull service, uint32_t chipAddress, uint32_t dataAddress,
                                    void * _Nonnull inputBuffer, uint32_t inputBufferSize);
