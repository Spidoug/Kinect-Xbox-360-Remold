/* Placeholder startup file. The exact ARM core, vector base, stack location,
 * cache/MMU state and ABI must be established from reverse engineering before
 * this target may be linked for hardware.
 */
    .section .text.startup
    .global remold_reset_entry
remold_reset_entry:
    b remold_firmware_main
