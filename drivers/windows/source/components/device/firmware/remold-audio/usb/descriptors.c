#include "descriptors.h"

/* Descriptor draft for the future runtime:
 * - UAC1 capture interface remains class-driver friendly.
 * - A separate vendor interface publishes acoustic scan frames.
 * VID 0xFFFF / PID 0x3601 are intentionally invalid development placeholders.
 * They MUST be replaced by a legitimately assigned VID/PID before hardware use.
 */
const uint8_t g_remold_usb_device_descriptor[] = {
    18, 1, 0x00,0x02, 0x00,0x00,0x00, 64,
    0xFF,0xFF, 0x01,0x36, 0x00,0x01, 1,2,3, 1
};
const size_t g_remold_usb_device_descriptor_size = sizeof(g_remold_usb_device_descriptor);

/* This is deliberately a schema skeleton rather than a claimed hardware-ready
 * descriptor. The UAC descriptors are filled only after the USB backend and
 * endpoint FIFO limits are confirmed from the reference firmware/TAS1020B path.
 */
const uint8_t g_remold_usb_configuration_descriptor[] = {
    9, 2, 18,0, 1, 1, 0, 0x80, 50,
    9, 4, 0, 0, 0, 0xFF, 0x52, 0x01, 0
};
const size_t g_remold_usb_configuration_descriptor_size = sizeof(g_remold_usb_configuration_descriptor);
