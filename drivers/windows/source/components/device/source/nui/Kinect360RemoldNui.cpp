#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <vector>
#include "Kinect360RemoldControlProtocol.h"
#include "Kinect360RemoldWinUsb.h"
#include "Kinect360RemoldHardwareProfile.h"

#pragma comment(lib, "setupapi.lib")

namespace {
using Kinect360RemoldControl::Command;
using Kinect360RemoldControl::Reply;
using Kinect360RemoldControl::Request;
using Kinect360RemoldControl::Transport;
namespace WinUsb = Kinect360RemoldWinUsb;
namespace Hardware = Kinect360RemoldHardware;

constexpr long kPhysicalDiagnosticMinimumDegrees = -31;
constexpr long kPhysicalDiagnosticMaximumDegrees = 31;

struct Device {
    HANDLE file = INVALID_HANDLE_VALUE;
    HANDLE pipe = INVALID_HANDLE_VALUE;
    WinUsb::Handle usb = nullptr;
    ~Device() {
        if (usb) WinUsb::Get().Free(usb);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
    }
};

int Usage() {
    std::puts(
        "Kinect360RemoldNui status | broker-status | tilt <deg> | "
        "led <off|green|red|yellow|blink-green|blink-yellow-red> | "
        "physical-status | physical-tilt <deg -31..31> | "
        "physical-led <off|green|red|yellow|blink-green|blink-yellow-red>");
    return 2;
}

HRESULT LastHr() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

HRESULT OpenByGuid(Device& device, const GUID& guid) {
    HDEVINFO set = SetupDiGetClassDevsW(&guid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return LastHr();

    HRESULT result = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA iface{};
        iface.cbSize = sizeof(iface);
        if (!SetupDiEnumDeviceInterfaces(set, nullptr, &guid, index, &iface)) {
            if (GetLastError() != ERROR_NO_MORE_ITEMS) result = LastHr();
            break;
        }

        DWORD bytes = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &iface, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<BYTE> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &iface, detail, bytes, nullptr, nullptr)) {
            result = LastHr();
            continue;
        }

        // Physical access is reserved for explicitly named diagnostic commands.
        device.file = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                                  FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr);
        if (device.file == INVALID_HANDLE_VALUE) {
            result = LastHr();
            continue;
        }
        if (!WinUsb::Ready() || !WinUsb::Get().Initialize(device.file, &device.usb)) {
            result = LastHr();
            CloseHandle(device.file);
            device.file = INVALID_HANDLE_VALUE;
            continue;
        }
        result = S_OK;
        break;
    }
    SetupDiDestroyDeviceInfoList(set);
    return result;
}

HRESULT PipeExchange(HANDLE pipe, const Request& request, Reply& reply) {
    DWORD written = 0;
    if (!WriteFile(pipe, &request, sizeof(request), &written, nullptr) || written != sizeof(request))
        return LastHr();
    DWORD read = 0;
    if (!ReadFile(pipe, &reply, sizeof(reply), &read, nullptr) || read != sizeof(reply))
        return LastHr();
    if (reply.magic != Kinect360RemoldControl::kMagic || reply.version != Kinect360RemoldControl::kVersion)
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    return static_cast<HRESULT>(reply.result);
}

HRESULT OpenControlPipe(Device& device) {
    // The broker protocol is transactional: one pipe connection carries one
    // Request and one Reply, so the caller opens a fresh pipe per command.
    constexpr DWORD kOpenAttempts = 4;
    HRESULT last = HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
    for (DWORD attempt = 0; attempt < kOpenAttempts; ++attempt) {
        if (!WaitNamedPipeW(Kinect360RemoldControl::kPipeName, 350)) {
            last = LastHr();
            continue;
        }
        device.pipe = CreateFileW(Kinect360RemoldControl::kPipeName,
                                  GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (device.pipe == INVALID_HANDLE_VALUE) {
            last = LastHr();
            continue;
        }
        DWORD mode = PIPE_READMODE_MESSAGE;
        if (!SetNamedPipeHandleState(device.pipe, &mode, nullptr, nullptr)) {
            last = LastHr();
            CloseHandle(device.pipe);
            device.pipe = INVALID_HANDLE_VALUE;
            continue;
        }
        return S_OK;
    }
    return last;
}

HRESULT BrokerExchange(Command command, int32_t value, Reply& reply) {
    Device device;
    const HRESULT openHr = OpenControlPipe(device);
    if (FAILED(openHr)) return openHr;
    Request request{};
    request.command = command;
    request.value = value;
    return PipeExchange(device.pipe, request, reply);
}

HRESULT OpenPhysical(Device& device) {
    return OpenByGuid(device, Hardware::kNuiTransportGuid);
}

HRESULT ControlPhysical(Device& device, UCHAR type, UCHAR request, USHORT value,
                        UCHAR* data, USHORT length, ULONG* done = nullptr) {
    WinUsb::SetupPacket packet{};
    packet.RequestType = type;
    packet.Request = request;
    packet.Value = value;
    packet.Index = 0;
    packet.Length = length;
    UINT transferred = 0;
    if (!WinUsb::Get().ControlTransfer(device.usb, packet, data, length, &transferred, nullptr)) return LastHr();
    if (done) *done = static_cast<ULONG>(transferred);
    return S_OK;
}

int ParseLed(const wchar_t* mode) {
    if (_wcsicmp(mode, L"off") == 0) return 0;
    if (_wcsicmp(mode, L"green") == 0) return 1;
    if (_wcsicmp(mode, L"red") == 0) return 2;
    if (_wcsicmp(mode, L"yellow") == 0) return 3;
    if (_wcsicmp(mode, L"blink-green") == 0) return 4;
    if (_wcsicmp(mode, L"blink-yellow-red") == 0) return 6;
    return -1;
}

bool ParseLong(const wchar_t* text, long& value) {
    wchar_t* end = nullptr;
    value = wcstol(text, &end, 10);
    return end && *end == L'\0';
}

int BrokerStatus(bool pingOnly) {
    Reply reply{};
    const HRESULT hr = BrokerExchange(pingOnly ? Command::Ping : Command::Status, 0, reply);
    if (FAILED(hr)) {
        std::printf("Broker command failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 7;
    }
    if (pingOnly) {
        std::printf("OK broker=ready camera-activity-mask=0x%X\n",
                    static_cast<unsigned int>(reply.cameraActivityMask));
    } else {
        std::printf("OK device=Xbox NUI Motor transport=broker accel=%d,%d,%d tilt=%.1f state=%u camera-activity-mask=0x%X\n",
                    reply.accelX, reply.accelY, reply.accelZ,
                    static_cast<double>(reply.tiltTenths) / 10.0,
                    static_cast<unsigned int>(reply.state),
                    static_cast<unsigned int>(reply.cameraActivityMask));
    }
    return 0;
}

int BrokerTilt(const wchar_t* text) {
    long value = 0;
    if (!ParseLong(text, value)) return Usage();
    Reply reply{};
    const HRESULT hr = BrokerExchange(Command::Tilt, static_cast<int32_t>(value), reply);
    if (FAILED(hr)) {
        std::printf("Broker Tilt failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 5;
    }
    std::printf("OK device=Xbox NUI Motor transport=broker tilt=%.1f\n",
                static_cast<double>(reply.tiltTenths) / 10.0);
    return 0;
}

int BrokerLed(const wchar_t* mode) {
    const int state = ParseLed(mode);
    if (state < 0) return Usage();
    Reply reply{};
    const HRESULT hr = BrokerExchange(Command::Led, state, reply);
    if (FAILED(hr)) {
        std::printf("Broker LED failed. HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 6;
    }
    std::printf("OK device=Xbox NUI Motor transport=broker led=%d\n", state);
    return 0;
}

int StatusPhysical(Device& device) {
    UCHAR buffer[10]{};
    ULONG got = 0;
    const HRESULT hr = ControlPhysical(device, 0xC0, 0x32, 0, buffer, sizeof(buffer), &got);
    if (FAILED(hr) || got != sizeof(buffer)) {
        std::printf("Xbox NUI Motor status failed: HRESULT=0x%08lX bytes=%lu\n",
                    static_cast<unsigned long>(hr), got);
        return 4;
    }

    const short x = static_cast<short>((buffer[2] << 8) | buffer[3]);
    const short y = static_cast<short>((buffer[4] << 8) | buffer[5]);
    const short z = static_cast<short>((buffer[6] << 8) | buffer[7]);
    const signed char angle = static_cast<signed char>(buffer[8]);
    std::printf("OK device=Xbox NUI Motor transport=physical-diagnostic accel=%d,%d,%d tilt=%.1f state=%u\n",
                x, y, z, static_cast<double>(angle) / 2.0, static_cast<unsigned>(buffer[9]));
    return 0;
}

int TiltPhysical(Device& device, const wchar_t* text) {
    long value = 0;
    if (!ParseLong(text, value)) return Usage();
    value = std::clamp(value, kPhysicalDiagnosticMinimumDegrees, kPhysicalDiagnosticMaximumDegrees);
    const SHORT protocolValue = static_cast<SHORT>(value * 2);
    const HRESULT hr = ControlPhysical(device, 0x40, 0x31, static_cast<USHORT>(protocolValue), nullptr, 0);
    if (FAILED(hr)) {
        std::printf("Xbox NUI Motor Tilt failed: HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 5;
    }
    std::printf("OK device=Xbox NUI Motor transport=physical-diagnostic tilt=%ld\n", value);
    return 0;
}

int LedPhysical(Device& device, const wchar_t* mode) {
    const int state = ParseLed(mode);
    if (state < 0) return Usage();
    const HRESULT hr = ControlPhysical(device, 0x40, 0x06, static_cast<USHORT>(state), nullptr, 0);
    if (FAILED(hr)) {
        std::printf("Xbox NUI Motor LED failed: HRESULT=0x%08lX\n", static_cast<unsigned long>(hr));
        return 6;
    }
    std::printf("OK device=Xbox NUI Motor transport=physical-diagnostic led=%d\n", state);
    return 0;
}

int OpenPhysicalOrReport(Device& device) {
    const HRESULT hr = OpenPhysical(device);
    if (FAILED(hr)) {
        std::printf("Xbox NUI Motor physical diagnostic transport is not available. HRESULT=0x%08lX\n",
                    static_cast<unsigned long>(hr));
        return 3;
    }
    return 0;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) return Usage();

    // Normal control is broker-only so FaceTracker, accelerometer, LED policy,
    // connection chirp and command-line operations share one serialized owner.
    if (_wcsicmp(argv[1], L"broker-status") == 0 && argc == 2) return BrokerStatus(true);
    if (_wcsicmp(argv[1], L"status") == 0 && argc == 2) return BrokerStatus(false);
    if (_wcsicmp(argv[1], L"tilt") == 0 && argc == 3) return BrokerTilt(argv[2]);
    if (_wcsicmp(argv[1], L"led") == 0 && argc == 3) return BrokerLed(argv[2]);

    const bool physicalStatus = _wcsicmp(argv[1], L"physical-status") == 0 && argc == 2;
    const bool physicalTilt = _wcsicmp(argv[1], L"physical-tilt") == 0 && argc == 3;
    const bool physicalLed = _wcsicmp(argv[1], L"physical-led") == 0 && argc == 3;
    if (!physicalStatus && !physicalTilt && !physicalLed) return Usage();

    Device device;
    const int openResult = OpenPhysicalOrReport(device);
    if (openResult != 0) return openResult;
    if (physicalStatus) return StatusPhysical(device);
    if (physicalTilt) return TiltPhysical(device, argv[2]);
    return LedPhysical(device, argv[2]);
}
