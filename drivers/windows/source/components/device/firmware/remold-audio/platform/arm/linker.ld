/* Provisional clean-room image layout derived only from the public upload
 * protocol: payloads are written beginning at 0x00080000. No MMIO addresses
 * or RAM sizes are guessed here. This script is not hardware-release ready.
 */
ENTRY(remold_firmware_main)
SECTIONS
{
  . = 0x00080000;
  .text : { *(.text.startup*) *(.text*) *(.rodata*) }
  .data : { *(.data*) }
  .bss (NOLOAD) : { *(.bss*) *(COMMON) }
}
