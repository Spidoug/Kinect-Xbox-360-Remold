#pragma once
#include <stdint.h>
#include "remold_acoustic_scan.h"

#define REMOLD_FW_PROTOCOL_MAGIC 0x53414D52u /* RMAS */
#define REMOLD_FW_PROTOCOL_VERSION 1u

typedef enum RemoldFirmwareCommand {
    REMOLD_FW_CMD_GET_INFO = 1,
    REMOLD_FW_CMD_START_RAW = 2,
    REMOLD_FW_CMD_START_PASSIVE_SCAN = 3,
    REMOLD_FW_CMD_ARM_ECHO_SCAN = 4,
    REMOLD_FW_CMD_STOP = 5,
    REMOLD_FW_CMD_SET_SOUND_SPEED = 6
} RemoldFirmwareCommand;

typedef struct RemoldFirmwareHeader {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t bytes;
    uint32_t sequence;
} RemoldFirmwareHeader;

typedef struct RemoldFirmwareInfo {
    RemoldFirmwareHeader header;
    uint32_t sample_rate_hz;
    uint32_t channels;
    uint32_t frame_samples;
    uint32_t azimuth_bins;
    uint32_t capabilities;
} RemoldFirmwareInfo;

enum {
    REMOLD_FW_CAP_RAW_AUDIO = 1u << 0,
    REMOLD_FW_CAP_SRP_PHAT = 1u << 1,
    REMOLD_FW_CAP_ACOUSTIC_OCCUPANCY = 1u << 2,
    REMOLD_FW_CAP_ACTIVE_ECHO = 1u << 3,
    REMOLD_FW_CAP_UAC1 = 1u << 4,
    REMOLD_FW_CAP_VENDOR_SCAN = 1u << 5
};
