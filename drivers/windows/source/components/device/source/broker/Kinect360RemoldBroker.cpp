#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <thread>
#include <vector>

#include "Kinect360RemoldControlProtocol.h"
#include "Kinect360RemoldDevicePolicy.h"
#include "Kinect360RemoldWinUsb.h"
#include "Kinect360RemoldHardwareProfile.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "advapi32.lib")

namespace {
using Kinect360RemoldControl::Command;
using Kinect360RemoldControl::Reply;
using Kinect360RemoldControl::Request;
using Kinect360RemoldControl::Transport;

namespace Policy = Kinect360RemoldDevicePolicy;
namespace WinUsb = Kinect360RemoldWinUsb;
namespace Hardware = Kinect360RemoldHardware;

std::atomic<bool> gRun{true};
std::mutex gPhysicalNuiMutex;
HRESULT HrFromLastError() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

enum class PhysicalTransportKind : uint8_t {
    None = 0,
    Classic1414,
    AudioControl1473,
};

struct PhysicalNuiSession {
    HANDLE file = INVALID_HANDLE_VALUE;
    WinUsb::Handle usb = nullptr;
    PhysicalTransportKind kind = PhysicalTransportKind::None;
    uint32_t nextTag = 0;
    UCHAR controlInEndpoint = 0;
    UCHAR controlOutEndpoint = 0;
    UCHAR controlAltSetting = 0;
    bool controlPipesReady = false;
    bool prepared = false;
    bool Ready() const noexcept { return file != INVALID_HANDLE_VALUE && usb != nullptr; }
    void Close() noexcept {
        if (usb) WinUsb::Get().Free(usb);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        usb = nullptr;
        file = INVALID_HANDLE_VALUE;
        kind = PhysicalTransportKind::None;
        nextTag = 0;
        controlInEndpoint = 0;
        controlOutEndpoint = 0;
        controlAltSetting = 0;
        controlPipesReady = false;
        prepared = false;
    }
    ~PhysicalNuiSession() { Close(); }
};

PhysicalNuiSession gPhysicalNuiSession;

constexpr DWORD kControlIoTimeoutMs = 5000;

bool Discover1473ControlPipes(PhysicalNuiSession& session) {
    if (!session.Ready() || session.kind != PhysicalTransportKind::AudioControl1473) return true;
    auto& api = WinUsb::Get();

    // Do not assume that the active alternate setting or endpoint numbers are
    // already what the firmware uses. The Microsoft Kinect Audio Array Control
    // package and our fallback both expose MI_00 through WinUSB, but the only
    // authoritative source is the live interface descriptor. This also catches
    // partial 02BB enumerations instead of converting them into ERROR_GEN_FAILURE
    // on the first command.
    for (UCHAR alt = 0; alt < 16; ++alt) {
        USB_INTERFACE_DESCRIPTOR descriptor{};
        if (!api.QueryInterfaceSettings(session.usb, alt, &descriptor)) continue;
        UCHAR in = 0;
        UCHAR out = 0;
        for (UCHAR index = 0; index < descriptor.bNumEndpoints; ++index) {
            WinUsb::PipeInformation pipe{};
            if (!api.QueryPipe(session.usb, alt, index, &pipe) || pipe.PipeType != UsbdPipeTypeBulk) continue;
            if ((pipe.PipeId & 0x80u) != 0) {
                if (!in || pipe.PipeId == Hardware::AudioControl::kInEndpoint) in = pipe.PipeId;
            } else {
                if (!out || pipe.PipeId == Hardware::AudioControl::kOutEndpoint) out = pipe.PipeId;
            }
        }
        if (!in || !out) continue;
        // WinUSB starts on alternate setting 0. Do not issue an unnecessary
        // SET_INTERFACE for the normal MI_00 layout; some 1473 firmware/host
        // combinations report a generic device failure for redundant requests.
        if (alt != 0 && !api.SetCurrentAlternateSetting(session.usb, alt)) return false;
        session.controlInEndpoint = in;
        session.controlOutEndpoint = out;
        session.controlAltSetting = alt;
        session.controlPipesReady = true;
        return true;
    }
    SetLastError(ERROR_NOT_READY);
    return false;
}

bool Validate1473RuntimeConfiguration(PhysicalNuiSession& session) {
    if (!session.Ready() || session.kind != PhysicalTransportKind::AudioControl1473) return true;
    USB_CONFIGURATION_DESCRIPTOR config{};
    ULONG transferred = 0;
    if (!WinUsb::Get().GetDescriptor(session.usb, USB_CONFIGURATION_DESCRIPTOR_TYPE, 0, 0,
                                     reinterpret_cast<PUCHAR>(&config), sizeof(config), &transferred))
        return false;
    if (transferred < sizeof(config) || config.bDescriptorType != USB_CONFIGURATION_DESCRIPTOR_TYPE) {
        SetLastError(ERROR_INVALID_DATA);
        return false;
    }
    // Interface count is not a capability gate on model 1473. Captured Xbox
    // runtimes may expose control and audio endpoints through a single interface,
    // while Kinect-for-Windows firmware can expose MI_00/MI_01/MI_02. The
    // authoritative control test is Discover1473ControlPipes(), which validates
    // the live bulk IN/OUT endpoints after this descriptor sanity check.
    if (config.bNumInterfaces == 0) {
        SetLastError(ERROR_NOT_READY);
        return false;
    }
    return true;
}

bool Configure1473ControlTimeouts(PhysicalNuiSession& session) {
    if (!session.Ready() || session.kind != PhysicalTransportKind::AudioControl1473) return true;
    if (!session.controlPipesReady && !Discover1473ControlPipes(session)) return false;

    // Keep WinUSB's PIPE_TRANSFER_TIMEOUT at its default (0). A non-zero pipe
    // policy makes the USB stack itself cancel requests and report
    // ERROR_SEM_TIMEOUT (121), which is exactly the failure seen on some 1473
    // controllers. The broker owns the timeout with OVERLAPPED I/O instead, so
    // a timeout cancels only the current request and the interface can be
    // reopened cleanly without leaving a host-controller timer armed.
    return true;
}

HRESULT OpenPhysicalInterface(const GUID& guid, PhysicalTransportKind kind, PhysicalNuiSession& session) {
    HDEVINFO set = SetupDiGetClassDevsW(
        &guid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return HrFromLastError();

    HRESULT result = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA iface{};
        iface.cbSize = sizeof(iface);
        if (!SetupDiEnumDeviceInterfaces(set, nullptr, &guid, index, &iface)) {
            if (GetLastError() != ERROR_NO_MORE_ITEMS) result = HrFromLastError();
            break;
        }

        DWORD bytes = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &iface, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<BYTE> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &iface, detail, bytes, nullptr, nullptr)) continue;

        HANDLE file = CreateFileW(
            detail->DevicePath,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
            nullptr);
        if (file == INVALID_HANDLE_VALUE) continue;

        WinUsb::Handle usb = nullptr;
        if (!WinUsb::Ready() || !WinUsb::Get().Initialize(file, &usb)) {
            result = HrFromLastError();
            CloseHandle(file);
            continue;
        }

        session.file = file;
        session.usb = usb;
        session.kind = kind;
        session.nextTag = 0;
        if (kind == PhysicalTransportKind::AudioControl1473 &&
            (!Validate1473RuntimeConfiguration(session) || !Configure1473ControlTimeouts(session))) {
            result = HrFromLastError();
            session.Close();
            continue;
        }
        result = S_OK;
        break;
    }

    SetupDiDestroyDeviceInfoList(set);
    return result;
}

HRESULT OpenPhysicalNui(PhysicalNuiSession& session) {
    // Prefer the dedicated 1414 motor function when present. 1473 has no
    // independent motor function: after UAC firmware, 02BB/02C3&MI_00 carries the
    // alternate motor/LED/accelerometer protocol.
    HRESULT hr = OpenPhysicalInterface(Hardware::kNuiTransportGuid, PhysicalTransportKind::Classic1414, session);
    if (SUCCEEDED(hr)) return hr;
    session.Close();
    return OpenPhysicalInterface(Hardware::kAudioControlTransportGuid, PhysicalTransportKind::AudioControl1473, session);
}

HRESULT EnsurePhysicalNui() {
    if (gPhysicalNuiSession.Ready()) return S_OK;
    gPhysicalNuiSession.Close();
    return OpenPhysicalNui(gPhysicalNuiSession);
}

#pragma pack(push, 1)
struct AltMotorCommand {
    uint32_t magic;
    uint32_t tag;
    uint32_t arg1;
    uint32_t command;
    uint32_t arg2;
};
struct AltMotorReply {
    uint32_t magic;
    uint32_t tag;
    uint32_t status;
};
#pragma pack(pop)
static_assert(sizeof(AltMotorCommand) == 20, "1473 motor command ABI");
static_assert(sizeof(AltMotorReply) == 12, "1473 motor reply ABI");

HRESULT Wait1473Overlapped(PhysicalNuiSession& session, OVERLAPPED& ov, UINT& transferred) {
    const DWORD wait = WaitForSingleObject(ov.hEvent, kControlIoTimeoutMs);
    if (wait == WAIT_OBJECT_0) {
        if (WinUsb::Get().GetOverlappedResult(session.usb, &ov, &transferred, FALSE)) return S_OK;
        return HrFromLastError();
    }
    if (wait == WAIT_TIMEOUT) {
        // Cancel only this I/O. Do not ResetPipe/FlushPipe here: MI_00 and the
        // UAC capture interface belong to the same 02BB composite device.
        CancelIoEx(session.file, &ov);
        WaitForSingleObject(ov.hEvent, 250);
        UINT ignored = 0;
        WinUsb::Get().GetOverlappedResult(session.usb, &ov, &ignored, FALSE);
        return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }
    return HrFromLastError();
}

HRESULT BulkWriteExact(PhysicalNuiSession& session, UCHAR endpoint, const void* data, UINT bytes) {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event) return HrFromLastError();
    OVERLAPPED ov{};
    ov.hEvent = event;
    UINT transferred = 0;
    BOOL ok = WinUsb::Get().WritePipe(session.usb, endpoint,
        reinterpret_cast<PUCHAR>(const_cast<void*>(data)), bytes, nullptr, &ov);
    HRESULT hr = S_OK;
    if (!ok) {
        const DWORD error = GetLastError();
        if (error == ERROR_IO_PENDING) hr = Wait1473Overlapped(session, ov, transferred);
        else hr = HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
    } else {
        hr = WinUsb::Get().GetOverlappedResult(session.usb, &ov, &transferred, FALSE)
            ? S_OK : HrFromLastError();
    }
    CloseHandle(event);
    if (FAILED(hr)) return hr;
    return transferred == bytes ? S_OK : HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
}

HRESULT BulkRead1473(PhysicalNuiSession& session, void* data, UINT bytes, UINT& transferred) {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event) return HrFromLastError();
    OVERLAPPED ov{};
    ov.hEvent = event;
    transferred = 0;
    BOOL ok = WinUsb::Get().ReadPipe(session.usb, session.controlInEndpoint,
        reinterpret_cast<PUCHAR>(data), bytes, nullptr, &ov);
    HRESULT hr = S_OK;
    if (!ok) {
        const DWORD error = GetLastError();
        if (error == ERROR_IO_PENDING) hr = Wait1473Overlapped(session, ov, transferred);
        else hr = HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
    } else {
        hr = WinUsb::Get().GetOverlappedResult(session.usb, &ov, &transferred, FALSE)
            ? S_OK : HrFromLastError();
    }
    CloseHandle(event);
    return hr;
}

HRESULT ReadAltAck(PhysicalNuiSession& session, uint32_t expectedTag) {
    std::array<UCHAR, 512> buffer{};
    UINT transferred = 0;
    const HRESULT readHr = BulkRead1473(
        session, buffer.data(), static_cast<UINT>(buffer.size()), transferred);
    if (FAILED(readHr)) return readHr;
    if (transferred != sizeof(AltMotorReply)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    AltMotorReply ack{};
    std::memcpy(&ack, buffer.data(), sizeof(ack));
    if (ack.magic != Hardware::AudioControl::kReplyMagic || ack.status != 0)
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

    // The alternate 1473/K4W firmware uses tags as a sequencing hint, but the
    // known-good libfreenect implementation deliberately does not reject a reply
    // solely because its tag differs. After a reset/re-enumeration a valid ACK can
    // carry the previous tag. Treat magic+status as authoritative; a failed transaction gets one bounded
    // pipe recovery and a failed retry invalidates the physical session.
    (void)expectedTag;
    return S_OK;
}

HRESULT SendAltCommandOnce(PhysicalNuiSession& session, uint32_t command, int32_t arg2) {
    const uint32_t tag = session.nextTag++;
    AltMotorCommand request{};
    request.magic = Hardware::AudioControl::kCommandMagic;
    request.tag = tag;
    request.arg1 = 0;
    request.command = command;
    request.arg2 = static_cast<uint32_t>(arg2);
    HRESULT hr = BulkWriteExact(session, session.controlOutEndpoint, &request, sizeof(request));
    if (FAILED(hr)) return hr;
    return ReadAltAck(session, tag);
}

HRESULT SendAltCommand(PhysicalNuiSession& session, uint32_t command, int32_t arg2) {
    return SendAltCommandOnce(session, command, arg2);
}

// The reference implementation resets the whole audio USB device before its
// one-shot keep-alive. WinUSB cannot safely emulate that here because MI_02 may
// already be the active Windows USB-Audio interface. V1 therefore uses a fresh
// MI_00 handle as the recovery boundary and never ResetPipe/FlushPipe on a
// healthy composite device. A failed command closes the handle and gets one
// clean reopen through the common retry contract.

void Recover1473ControlAfterFailure(PhysicalNuiSession& session) {
    if (!session.Ready() || session.kind != PhysicalTransportKind::AudioControl1473 ||
        !session.controlPipesReady) return;
    auto& api = WinUsb::Get();
    // Error-only recovery. Never run this during a healthy open: MI_02 may be
    // streaming through the same 02BB composite. Clearing only MI_00 here gives
    // a stalled bulk endpoint one chance to recover before the common fresh-
    // handle retry, without any PnP restart/re-enumeration.
    (void)api.AbortPipe(session.usb, session.controlInEndpoint);
    (void)api.AbortPipe(session.usb, session.controlOutEndpoint);
    (void)api.ResetPipe(session.usb, session.controlInEndpoint);
    (void)api.ResetPipe(session.usb, session.controlOutEndpoint);
    (void)api.FlushPipe(session.usb, session.controlInEndpoint);
}

HRESULT Prepare1473Control(PhysicalNuiSession& session) {
    if (session.kind != PhysicalTransportKind::AudioControl1473) return S_OK;
    if (session.prepared) return S_OK;
    if (!session.controlPipesReady && !Discover1473ControlPipes(session))
        return HrFromLastError();

    // Same semantic keep-alive used by libfreenect for 1473/K4W, but without
    // resetting the whole 02BB composite. A fresh MI_00 handle starts at tag 0.
    session.nextTag = 0;
    const HRESULT hr = SendAltCommandOnce(
        session, Hardware::AudioControl::kLedCommand, 3);
    if (SUCCEEDED(hr)) session.prepared = true;
    return hr;
}

HRESULT Prepare1414Control(PhysicalNuiSession&) {
    return S_OK;
}

void Recover1414ControlAfterFailure(PhysicalNuiSession&) {
}

HRESULT ReadStatus1414(PhysicalNuiSession& session, Reply& reply) {
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0xC0;
    packet.Request = 0x32;
    packet.Length = 10;
    UCHAR buffer[10]{};
    UINT transferred = 0;
    if (!WinUsb::Get().ControlTransfer(session.usb, packet, buffer, sizeof(buffer), &transferred, nullptr) ||
        transferred != sizeof(buffer)) return HrFromLastError();

    reply.accelX = static_cast<short>((buffer[2] << 8) | buffer[3]);
    reply.accelY = static_cast<short>((buffer[4] << 8) | buffer[5]);
    reply.accelZ = static_cast<short>((buffer[6] << 8) | buffer[7]);
    reply.tiltTenths = static_cast<signed char>(buffer[8]) * 5;
    reply.state = buffer[9];
    return S_OK;
}

HRESULT ReadStatus1473(PhysicalNuiSession& session, Reply& reply) {
    const uint32_t tag = session.nextTag++;
    AltMotorCommand request{};
    request.magic = Hardware::AudioControl::kCommandMagic;
    request.tag = tag;
    request.arg1 = Hardware::AudioControl::kStatusReplyBytes;
    request.command = Hardware::AudioControl::kStatusCommand;

    // 1473 status is transported differently, but it is normalized into the
    // exact same logical Reply fields consumed by every caller.
    HRESULT hr = BulkWriteExact(session, session.controlOutEndpoint, &request, 16);
    if (FAILED(hr)) return hr;

    UCHAR buffer[256]{};
    UINT transferred = 0;
    hr = BulkRead1473(session, buffer, sizeof(buffer), transferred);
    if (FAILED(hr)) return hr;
    if (transferred != Hardware::AudioControl::kStatusReplyBytes)
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

    int32_t values[4]{};
    std::memcpy(values, buffer + 16, sizeof(values));
    reply.accelX = static_cast<short>(values[0]);
    reply.accelY = static_cast<short>(values[1]);
    reply.accelZ = static_cast<short>(values[2]);
    reply.tiltTenths = values[3] * 10;
    reply.state = 0; // the alternate status frame does not expose 1414's raw motor-state byte
    return ReadAltAck(session, tag);
}

HRESULT IssueTilt1414(PhysicalNuiSession& session, LONG degrees) {
    // Connection detail only: classic motor control encodes the same logical
    // angle in half-degree units through request 0x31.
    const SHORT halfDegrees = static_cast<SHORT>(degrees * 2);
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0x40;
    packet.Request = 0x31;
    packet.Value = static_cast<USHORT>(halfDegrees);
    UINT transferred = 0;
    return WinUsb::Get().ControlTransfer(
        session.usb, packet, nullptr, 0, &transferred, nullptr) ? S_OK : HrFromLastError();
}

HRESULT IssueTilt1473(PhysicalNuiSession& session, LONG degrees) {
    // Connection detail only: 1473 carries the same logical angle in whole
    // degrees through the alternate 0x803B command on 02BB/02C3&MI_00.
    return SendAltCommand(session, Hardware::AudioControl::kTiltCommand,
                          static_cast<int32_t>(degrees));
}

HRESULT SetLed1414(PhysicalNuiSession& session, LONG value) {
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0x40;
    packet.Request = 0x06;
    packet.Value = static_cast<USHORT>(value);
    UINT transferred = 0;
    return WinUsb::Get().ControlTransfer(session.usb, packet, nullptr, 0, &transferred, nullptr)
        ? S_OK : HrFromLastError();
}

HRESULT SetLed1473(PhysicalNuiSession& session, LONG value) {
    // Normalize the common LED contract onto the subset exposed by the 1473
    // alternate controller. Yellow degrades to green and compound blink to the
    // closest supported state, while success/failure semantics remain common.
    int32_t alt = 3;
    if (value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Off)) alt = 1;
    else if (value == static_cast<LONG>(Kinect360RemoldControl::LedMode::BlinkGreen)) alt = 2;
    else if (value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Red)) alt = 4;
    else if (value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Green) ||
             value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Yellow)) alt = 3;

    if (!session.controlPipesReady && !Discover1473ControlPipes(session))
        return HrFromLastError();
    const HRESULT hr = SendAltCommand(session, Hardware::AudioControl::kLedCommand, alt);
    if (SUCCEEDED(hr)) session.prepared = true;
    return hr;
}

struct PhysicalControlOps {
    HRESULT (*prepare)(PhysicalNuiSession&);
    HRESULT (*readStatus)(PhysicalNuiSession&, Reply&);
    HRESULT (*issueTilt)(PhysicalNuiSession&, LONG);
    HRESULT (*setLed)(PhysicalNuiSession&, LONG);
    void (*recoverAfterFailure)(PhysicalNuiSession&);
};

const PhysicalControlOps* ControlOpsFor(PhysicalTransportKind kind) {
    static const PhysicalControlOps k1414{Prepare1414Control, ReadStatus1414, IssueTilt1414, SetLed1414, Recover1414ControlAfterFailure};
    static const PhysicalControlOps k1473{Prepare1473Control, ReadStatus1473, IssueTilt1473, SetLed1473, Recover1473ControlAfterFailure};
    switch (kind) {
        case PhysicalTransportKind::Classic1414: return &k1414;
        case PhysicalTransportKind::AudioControl1473: return &k1473;
        default: return nullptr;
    }
}

HRESULT ReadPhysicalStatus(PhysicalNuiSession& session, Reply& reply) {
    const PhysicalControlOps* ops = ControlOpsFor(session.kind);
    if (!ops) return E_HANDLE;
    return ops->readStatus(session, reply);
}

HRESULT WaitForTiltTarget(PhysicalNuiSession& session, LONG degrees, Reply& observed) {
    constexpr LONG kToleranceTenths = 15; // same 1.5-degree success contract for both revisions
    constexpr DWORD kInitialSettleMs = 120;
    constexpr DWORD kPollMs = 100;
    constexpr int kPollCount = 40;
    const LONG targetTenths = degrees * 10;

    Sleep(kInitialSettleMs);
    HRESULT lastHr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    bool receivedStatus = false;
    LONG firstTenths = 0;
    LONG lastTenths = 0;
    bool firstValid = false;

    for (int attempt = 0; attempt < kPollCount; ++attempt) {
        Reply latest{};
        lastHr = ReadPhysicalStatus(session, latest);
        if (SUCCEEDED(lastHr)) {
            receivedStatus = true;
            observed = latest;
            lastTenths = latest.tiltTenths;
            if (!firstValid) {
                firstTenths = lastTenths;
                firstValid = true;
            }
            if (std::abs(lastTenths - targetTenths) <= kToleranceTenths) return S_OK;
        } else if (HRESULT_CODE(lastHr) != ERROR_TIMEOUT) {
            return lastHr;
        }
        Sleep(kPollMs);
    }

    if (!receivedStatus) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    // Same result semantics on both revisions: accepted-but-unverified movement
    // is never OK. A stationary mechanism reports I/O failure; movement that
    // did not settle at the target reports timeout.
    const bool moved = firstValid && std::abs(lastTenths - firstTenths) >= 5;
    return HRESULT_FROM_WIN32(moved ? ERROR_TIMEOUT : ERROR_IO_DEVICE);
}

HRESULT SetPhysicalTiltDegrees(PhysicalNuiSession& session, LONG requestedDegrees, Reply& observed) {
    const LONG degrees = std::clamp<LONG>(requestedDegrees, Policy::kTiltMinDegrees, Policy::kTiltMaxDegrees);
    const PhysicalControlOps* ops = ControlOpsFor(session.kind);
    if (!ops) return E_HANDLE;

    const HRESULT issueHr = ops->issueTilt(session, degrees);
    if (FAILED(issueHr)) return issueHr;
    return WaitForTiltTarget(session, degrees, observed);
}

bool IsValidLedMode(LONG value) {
    return value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Off) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Green) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Red) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Yellow) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::BlinkGreen) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::BlinkYellowRed);
}

HRESULT SetPhysicalLed(PhysicalNuiSession& session, LONG value) {
    if (!IsValidLedMode(value)) return E_INVALIDARG;
    const PhysicalControlOps* ops = ControlOpsFor(session.kind);
    if (!ops) return E_HANDLE;
    return ops->setLed(session, value);
}

HRESULT TryPhysicalNuiCommand(const Request& request, Reply& reply) {
    // Status, Tilt and LED share one serialized physical-control owner. Every
    // backend gets the same one-fresh-handle retry contract. Backend-specific
    // USB recovery remains local to the connection implementation.
    std::lock_guard<std::mutex> physicalGuard(gPhysicalNuiMutex);

    auto execute = [&](Reply& out) -> HRESULT {
        const HRESULT openHr = EnsurePhysicalNui();
        if (FAILED(openHr)) return openHr;
        out = {};
        out.transport = Transport::PhysicalMotor;
        if (request.command == Command::Ping) return S_OK;
        const PhysicalControlOps* ops = ControlOpsFor(gPhysicalNuiSession.kind);
        if (!ops) return E_HANDLE;
        if (request.command == Command::PrepareCamera) return ops->prepare(gPhysicalNuiSession);
        if (request.command == Command::Status) {
            const HRESULT prepareHr = ops->prepare(gPhysicalNuiSession);
            if (FAILED(prepareHr)) return prepareHr;
            return ReadPhysicalStatus(gPhysicalNuiSession, out);
        }
        if (request.command == Command::Tilt) {
            const HRESULT prepareHr = ops->prepare(gPhysicalNuiSession);
            if (FAILED(prepareHr)) return prepareHr;
            const LONG degrees = std::clamp<LONG>(request.value, Policy::kTiltMinDegrees, Policy::kTiltMaxDegrees);
            return SetPhysicalTiltDegrees(gPhysicalNuiSession, degrees, out);
        }
        if (request.command == Command::Led) return SetPhysicalLed(gPhysicalNuiSession, request.value);
        return E_INVALIDARG;
    };

    HRESULT hr = execute(reply);
    if (SUCCEEDED(hr)) return hr;

    // One fresh-handle retry is part of the common contract. Each backend may
    // perform only its connection-local error recovery before the handle is
    // closed; the public retry path remains revision-neutral.
    if (const PhysicalControlOps* ops = ControlOpsFor(gPhysicalNuiSession.kind); ops && ops->recoverAfterFailure)
        ops->recoverAfterFailure(gPhysicalNuiSession);
    gPhysicalNuiSession.Close();
    Sleep(50);
    hr = execute(reply);
    if (FAILED(hr)) gPhysicalNuiSession.Close();
    return hr;
}

HRESULT DispatchControlRequest(const Request& request, Reply& reply) {
    reply = {};
    if (request.magic != Kinect360RemoldControl::kMagic ||
        request.version != Kinect360RemoldControl::kVersion) {
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }

    switch (request.command) {
        case Command::Ping:
            return S_OK;
        case Command::Status:
        case Command::Tilt:
        case Command::Led:
        case Command::PrepareCamera:
            return TryPhysicalNuiCommand(request, reply);
        default:
            return E_INVALIDARG;
    }
}

void ControlServerLoop(std::atomic<bool>* active) {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)",
            SDDL_REVISION_1,
            &descriptor,
            nullptr)) {
        security.lpSecurityDescriptor = descriptor;
    }

    while (active->load() && gRun.load()) {
        HANDLE pipe = CreateNamedPipeW(
            Kinect360RemoldControl::kPipeName,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            4,
            sizeof(Reply),
            sizeof(Request),
            1000,
            security.lpSecurityDescriptor ? &security : nullptr);
        if (pipe == INVALID_HANDLE_VALUE) {
            Sleep(250);
            continue;
        }

        BOOL connected = ConnectNamedPipe(pipe, nullptr);
        if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = TRUE;
        if (connected) {
            Request request{};
            DWORD read = 0;
            if (ReadFile(pipe, &request, sizeof(request), &read, nullptr) && read == sizeof(request)) {
                Reply reply{};
                const HRESULT hr = DispatchControlRequest(request, reply);
                reply.result = static_cast<int32_t>(hr);
                DWORD written = 0;
                (void)WriteFile(pipe, &reply, sizeof(reply), &written, nullptr);
                (void)FlushFileBuffers(pipe);
            }
            (void)DisconnectNamedPipe(pipe);
        }
        CloseHandle(pipe);
    }
    if (descriptor) LocalFree(descriptor);
}

void WakeControlServer() {
    if (!WaitNamedPipeW(Kinect360RemoldControl::kPipeName, 100)) return;
    HANDLE pipe = CreateFileW(
        Kinect360RemoldControl::kPipeName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return;
    Request request{};
    request.command = Command::Ping;
    DWORD written = 0;
    (void)WriteFile(pipe, &request, sizeof(request), &written, nullptr);
    Reply reply{};
    DWORD read = 0;
    (void)ReadFile(pipe, &reply, sizeof(reply), &read, nullptr);
    CloseHandle(pipe);
}

int RunHost() {
    std::atomic<bool> brokerRun{true};
    std::thread controlThread(ControlServerLoop, &brokerRun);
    while (gRun.load()) Sleep(250);
    brokerRun.store(false);
    WakeControlServer();
    if (controlThread.joinable()) controlThread.join();
    return 0;
}

SERVICE_STATUS_HANDLE gServiceHandle = nullptr;
SERVICE_STATUS gServiceStatus{};

void WINAPI ServiceControl(DWORD control) {
    if (control != SERVICE_CONTROL_STOP && control != SERVICE_CONTROL_SHUTDOWN) return;
    gRun.store(false);
    gServiceStatus.dwCurrentState = SERVICE_STOP_PENDING;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwCheckPoint = 1;
    gServiceStatus.dwWaitHint = 5000;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
    gServiceHandle = RegisterServiceCtrlHandlerW(L"Kinect360RemoldBroker", ServiceControl);
    if (!gServiceHandle) return;

    gServiceStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    gServiceStatus.dwCurrentState = SERVICE_START_PENDING;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwWin32ExitCode = NO_ERROR;
    gServiceStatus.dwCheckPoint = 1;
    gServiceStatus.dwWaitHint = 5000;
    SetServiceStatus(gServiceHandle, &gServiceStatus);

    gRun.store(true);
    gServiceStatus.dwCurrentState = SERVICE_RUNNING;
    gServiceStatus.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    gServiceStatus.dwCheckPoint = 0;
    gServiceStatus.dwWaitHint = 0;
    SetServiceStatus(gServiceHandle, &gServiceStatus);

    (void)RunHost();

    gServiceStatus.dwCurrentState = SERVICE_STOPPED;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwCheckPoint = 0;
    gServiceStatus.dwWaitHint = 0;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && _wcsicmp(argv[1], L"--console") == 0) {
        gRun.store(true);
        return RunHost();
    }

    SERVICE_TABLE_ENTRYW table[] = {
        { const_cast<LPWSTR>(L"Kinect360RemoldBroker"), ServiceMain },
        { nullptr, nullptr }
    };
    if (StartServiceCtrlDispatcherW(table)) return 0;

    const DWORD error = GetLastError();
    if (error == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
        gRun.store(true);
        return RunHost();
    }
    return static_cast<int>(error);
}
