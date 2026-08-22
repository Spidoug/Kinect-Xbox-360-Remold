#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winusb.h>
#include <winusbio.h>
#include <usb.h>

#include <cstdint>
#include <mutex>
#include <new>
#include <vector>

// Runtime-loaded Microsoft WinUSB helper shared by Remold user-mode USB code.
// In the NUI Audio path, 02AD uses WinUSB only while it is the firmware boot
// transport. After Microsoft UACFirmware launches, the 02BB MI_02 runtime is
// owned by the inbox USB Audio class driver and AudioBridge captures via WASAPI.
// The ISO helpers remain available to other WinUSB transports but are not used
// to capture the UAC microphone runtime.
namespace Kinect360RemoldWinUsb {

using Handle = WINUSB_INTERFACE_HANDLE;

struct SetupPacket {
    UCHAR RequestType;
    UCHAR Request;
    USHORT Value;
    USHORT Index;
    USHORT Length;
};
static_assert(sizeof(SetupPacket) == sizeof(WINUSB_SETUP_PACKET), "WinUSB setup packet ABI");

struct PipeInformation {
    USBD_PIPE_TYPE PipeType = UsbdPipeTypeControl;
    UCHAR PipeId = 0;
    USHORT MaximumPacketSize = 0;
    UCHAR Interval = 0;
    ULONG MaximumBytesPerInterval = 0;
};

struct IsoPacket {
    UINT Offset = 0;
    UINT Length = 0;
    UINT Status = 0;
};
static_assert(sizeof(IsoPacket) == sizeof(USBD_ISO_PACKET_DESCRIPTOR), "WinUSB ISO packet ABI");

constexpr UINT kDeviceInformationSpeed = 0x01;
constexpr UINT kIsoStatusSuccess = USBD_STATUS_SUCCESS;
// WinUSB requires the first asynchronous request of a stream to start a new
// schedule (FALSE). Requests queued behind it should continue that schedule
// (TRUE). Callers may fall back to FALSE after a real discontinuity. Keeping
// both values named avoids ad-hoc booleans in camera/audio transports.
constexpr BOOL kIsoStartStream = FALSE;
constexpr BOOL kIsoContinueStream = TRUE;

inline ULONG EffectiveIsoBytesPerInterval(const PipeInformation& pipe) noexcept {
    if (pipe.MaximumBytesPerInterval) return pipe.MaximumBytesPerInterval;
    const ULONG raw = pipe.MaximumPacketSize;
    const ULONG payload = raw & 0x07ffu;
    const ULONG transactions = 1u + ((raw >> 11u) & 0x03u);
    return pipe.PipeType == UsbdPipeTypeIsochronous ? payload * transactions : payload;
}

// Windows' high-speed isochronous scheduler supports polling periods of 1, 2,
// 4 or 8 microframes. USB bInterval values above 4 represent 16+ microframes
// and cannot be submitted by the Windows USB stack. Keep this transport rule
// shared so camera and NUI Audio reject the same impossible geometry.
inline bool IsIsoIntervalSupportedByWindows(UCHAR deviceSpeed, UCHAR interval) noexcept {
    if (!interval) return false;
    constexpr UCHAR kUsbHighSpeed = 3;
    return deviceSpeed < kUsbHighSpeed || interval <= 4;
}

struct IsoBufferRegistration {
    WINUSB_ISOCH_BUFFER_HANDLE handle = nullptr;
    PUCHAR buffer = nullptr;
    ULONG length = 0;
    UCHAR pipeId = 0;
};

struct IsoContext {
    INT packetCount = 0;
    INT packetBytes = 0;
    std::vector<USBD_ISO_PACKET_DESCRIPTOR> packets;
};

class Api final {
public:
    static Api& Instance() {
        static Api api;
        return api;
    }

    bool EnsureLoaded() {
        std::call_once(m_once, [this] { Load(); });
        if (!m_ready) SetLastError(m_loadError ? m_loadError : ERROR_MOD_NOT_FOUND);
        return m_ready;
    }

    DWORD LoadError() const noexcept { return m_loadError; }

    BOOL Initialize(HANDLE file, Handle* handle) const {
        return m_initialize ? m_initialize(file, handle) : FailBool();
    }
    BOOL Free(Handle handle) const { return m_free ? m_free(handle) : FailBool(); }
    BOOL GetAssociatedInterface(Handle handle, UCHAR index, Handle* associated) const {
        return m_getAssociatedInterface ? m_getAssociatedInterface(handle, index, associated) : FailBool();
    }
    BOOL QueryInterfaceSettings(Handle handle, UCHAR alt, PUSB_INTERFACE_DESCRIPTOR descriptor) const {
        return m_queryInterfaceSettings ? m_queryInterfaceSettings(handle, alt, descriptor) : FailBool();
    }
    BOOL QueryDeviceInformation(Handle handle, UINT type, PUINT length, PVOID buffer) const {
        return m_queryDeviceInformation ? m_queryDeviceInformation(handle, type, length, buffer) : FailBool();
    }
    BOOL GetDescriptor(Handle handle, UCHAR descriptorType, UCHAR index, USHORT languageId,
                       PUCHAR buffer, ULONG bufferLength, PULONG transferred) const {
        return m_getDescriptor
            ? m_getDescriptor(handle, descriptorType, index, languageId, buffer, bufferLength, transferred)
            : FailBool();
    }
    BOOL SetCurrentAlternateSetting(Handle handle, UCHAR alt) const {
        return m_setCurrentAlternateSetting ? m_setCurrentAlternateSetting(handle, alt) : FailBool();
    }

    // QueryPipeEx is important for periodic endpoints: MaximumPacketSize alone
    // is not sufficient for high-bandwidth/high-speed isochronous pipes.
    BOOL QueryPipe(Handle handle, UCHAR alt, UCHAR index, PipeInformation* pipe) const {
        if (!pipe) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
        *pipe = {};
        if (m_queryPipeEx) {
            WINUSB_PIPE_INFORMATION_EX native{};
            if (!m_queryPipeEx(handle, alt, index, &native)) return FALSE;
            pipe->PipeType = native.PipeType;
            pipe->PipeId = native.PipeId;
            pipe->MaximumPacketSize = native.MaximumPacketSize;
            pipe->Interval = native.Interval;
            pipe->MaximumBytesPerInterval = native.MaximumBytesPerInterval;
            return TRUE;
        }
        if (!m_queryPipe) return FailBool();
        WINUSB_PIPE_INFORMATION native{};
        if (!m_queryPipe(handle, alt, index, &native)) return FALSE;
        pipe->PipeType = native.PipeType;
        pipe->PipeId = native.PipeId;
        pipe->MaximumPacketSize = native.MaximumPacketSize;
        pipe->Interval = native.Interval;
        pipe->MaximumBytesPerInterval = EffectiveIsoBytesPerInterval(*pipe);
        return TRUE;
    }

    BOOL ControlTransfer(Handle handle, SetupPacket packet, PUCHAR buffer, UINT length, PUINT transferred, LPOVERLAPPED ov) const {
        if (!m_controlTransfer) return FailBool();
        WINUSB_SETUP_PACKET native{};
        native.RequestType = packet.RequestType;
        native.Request = packet.Request;
        native.Value = packet.Value;
        native.Index = packet.Index;
        native.Length = packet.Length;
        return m_controlTransfer(handle, native, buffer, length, transferred, ov);
    }
    BOOL ReadPipe(Handle handle, UCHAR pipe, PUCHAR buffer, UINT length, PUINT transferred, LPOVERLAPPED ov) const {
        return m_readPipe ? m_readPipe(handle, pipe, buffer, length, transferred, ov) : FailBool();
    }
    BOOL WritePipe(Handle handle, UCHAR pipe, PUCHAR buffer, UINT length, PUINT transferred, LPOVERLAPPED ov) const {
        return m_writePipe ? m_writePipe(handle, pipe, buffer, length, transferred, ov) : FailBool();
    }
    BOOL ResetPipe(Handle handle, UCHAR pipe) const { return m_resetPipe ? m_resetPipe(handle, pipe) : FailBool(); }
    BOOL AbortPipe(Handle handle, UCHAR pipe) const { return m_abortPipe ? m_abortPipe(handle, pipe) : FailBool(); }
    BOOL FlushPipe(Handle handle, UCHAR pipe) const { return m_flushPipe ? m_flushPipe(handle, pipe) : FailBool(); }
    BOOL GetOverlappedResult(Handle handle, LPOVERLAPPED ov, PUINT transferred, BOOL wait) const {
        return m_getOverlappedResult ? m_getOverlappedResult(handle, ov, transferred, wait) : FailBool();
    }

    BOOL IsoInit(IsoContext** context, INT packetCount, INT) const {
        if (!context || packetCount <= 0) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
        auto* value = new (std::nothrow) IsoContext();
        if (!value) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return FALSE; }
        value->packetCount = packetCount;
        try { value->packets.resize(static_cast<size_t>(packetCount)); }
        catch (...) { delete value; SetLastError(ERROR_NOT_ENOUGH_MEMORY); return FALSE; }
        *context = value;
        return TRUE;
    }

    BOOL IsoFree(IsoContext* context) const {
        delete context;
        return TRUE;
    }

    BOOL IsoRegisterBuffer(Handle handle, UCHAR pipe, PUCHAR buffer, ULONG length,
                           IsoBufferRegistration* registration) const {
        if (!registration || registration->handle || !handle || !buffer || !length) {
            SetLastError(ERROR_INVALID_PARAMETER); return FALSE;
        }
        if (!m_registerIsochBuffer) return FailBool();
        WINUSB_ISOCH_BUFFER_HANDLE native = nullptr;
        if (!m_registerIsochBuffer(handle, pipe, buffer, length, &native)) return FALSE;
        registration->handle = native;
        registration->buffer = buffer;
        registration->length = length;
        registration->pipeId = pipe;
        return TRUE;
    }

    BOOL IsoUnregisterBuffer(IsoBufferRegistration* registration) const {
        if (!registration) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
        BOOL ok = TRUE;
        if (registration->handle) {
            if (!m_unregisterIsochBuffer) return FailBool();
            ok = m_unregisterIsochBuffer(registration->handle);
        }
        *registration = {};
        return ok;
    }

    BOOL IsoSetPackets(IsoContext* context, INT packetBytes) const {
        if (!context || packetBytes <= 0) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
        context->packetBytes = packetBytes;
        return TRUE;
    }

    BOOL IsoReuse(IsoContext* context) const {
        if (!context) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
        for (auto& packet : context->packets) packet = {};
        return TRUE;
    }

    BOOL IsoGetPacket(IsoContext* context, INT index, IsoPacket* packet) const {
        if (!context || !packet || index < 0 || index >= context->packetCount) {
            SetLastError(ERROR_INVALID_PARAMETER); return FALSE;
        }
        const auto& native = context->packets[static_cast<size_t>(index)];
        packet->Offset = native.Offset;
        packet->Length = native.Length;
        packet->Status = native.Status;
        return TRUE;
    }

    BOOL IsoReadPipe(const IsoBufferRegistration* registration, ULONG offset, UINT length,
                     BOOL continueStream, LPOVERLAPPED ov, IsoContext* context) const {
        if (!ValidateIsoTransfer(registration, offset, length, context)) return FALSE;
        if (!m_readIsochPipeAsap) return FailBool();
        return m_readIsochPipeAsap(registration->handle, offset, length, continueStream,
                                   static_cast<ULONG>(context->packetCount), context->packets.data(), ov);
    }

    BOOL IsoWritePipe(const IsoBufferRegistration* registration, ULONG offset, UINT length,
                      BOOL continueStream, LPOVERLAPPED ov, IsoContext* context) const {
        if (!ValidateIsoTransfer(registration, offset, length, context)) return FALSE;
        if (!m_writeIsochPipeAsap) return FailBool();
        return m_writeIsochPipeAsap(registration->handle, offset, length, continueStream, ov);
    }

    // ContinueStream=TRUE is desirable while a queue is continuous, but WinUSB
    // explicitly rejects it when the next request can no longer be placed right
    // after the last pending transfer.  A transient scheduling gap must not kill
    // the whole camera/audio session: retry exactly once as a fresh stream and
    // then mark the queue primed again.  Geometry/handle validation is still
    // performed by the low-level methods, so ERROR_INVALID_PARAMETER here is
    // specifically the tolerant continuity recovery case.
    BOOL IsoReadPipeStreaming(const IsoBufferRegistration* registration, ULONG offset, UINT length,
                              bool* streamPrimed, LPOVERLAPPED ov, IsoContext* context) const {
        if (!streamPrimed) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
        const BOOL continuation = *streamPrimed ? kIsoContinueStream : kIsoStartStream;
        BOOL ok = IsoReadPipe(registration, offset, length, continuation, ov, context);
        DWORD error = ok ? ERROR_SUCCESS : GetLastError();
        if (!ok && error != ERROR_IO_PENDING && continuation == kIsoContinueStream &&
            error == ERROR_INVALID_PARAMETER) {
            ok = IsoReadPipe(registration, offset, length, kIsoStartStream, ov, context);
            error = ok ? ERROR_SUCCESS : GetLastError();
        }
        if (ok || error == ERROR_IO_PENDING) *streamPrimed = true;
        if (!ok) SetLastError(error);
        return ok;
    }

    BOOL IsoWritePipeStreaming(const IsoBufferRegistration* registration, ULONG offset, UINT length,
                               bool* streamPrimed, LPOVERLAPPED ov, IsoContext* context) const {
        if (!streamPrimed) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
        const BOOL continuation = *streamPrimed ? kIsoContinueStream : kIsoStartStream;
        BOOL ok = IsoWritePipe(registration, offset, length, continuation, ov, context);
        DWORD error = ok ? ERROR_SUCCESS : GetLastError();
        if (!ok && error != ERROR_IO_PENDING && continuation == kIsoContinueStream &&
            error == ERROR_INVALID_PARAMETER) {
            ok = IsoWritePipe(registration, offset, length, kIsoStartStream, ov, context);
            error = ok ? ERROR_SUCCESS : GetLastError();
        }
        if (ok || error == ERROR_IO_PENDING) *streamPrimed = true;
        if (!ok) SetLastError(error);
        return ok;
    }

    // USBD_ISO_PACKET_DESCRIPTOR::Offset is relative to the transfer request,
    // while WinUsb_ReadIsochPipeAsap's Offset selects that request inside the
    // registered pool. Keep this address arithmetic in one place so camera and
    // audio cannot accidentally interpret packet offsets differently.
    BOOL IsoPacketData(const IsoBufferRegistration* registration, ULONG transferOffset,
                       UINT transferLength, const IsoPacket& packet, PUCHAR* data) const {
        if (!registration || !registration->buffer || !registration->length || !data ||
            transferOffset > registration->length || transferLength > registration->length - transferOffset ||
            packet.Offset > transferLength || packet.Length > transferLength - packet.Offset) {
            SetLastError(ERROR_INVALID_DATA); return FALSE;
        }
        *data = registration->buffer + transferOffset + packet.Offset;
        return TRUE;
    }

private:
    using InitializeFn = BOOL (WINAPI*)(HANDLE, PWINUSB_INTERFACE_HANDLE);
    using FreeFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE);
    using GetAssociatedInterfaceFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR, PWINUSB_INTERFACE_HANDLE);
    using QueryInterfaceSettingsFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR, PUSB_INTERFACE_DESCRIPTOR);
    using QueryDeviceInformationFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UINT, PUINT, PVOID);
    using GetDescriptorFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR, UCHAR, USHORT, PUCHAR, ULONG, PULONG);
    using SetCurrentAlternateSettingFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR);
    using QueryPipeFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR, UCHAR, PWINUSB_PIPE_INFORMATION);
    using QueryPipeExFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR, UCHAR, PWINUSB_PIPE_INFORMATION_EX);
    using ControlTransferFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, WINUSB_SETUP_PACKET, PUCHAR, UINT, PUINT, LPOVERLAPPED);
    using ReadPipeFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR, PUCHAR, UINT, PUINT, LPOVERLAPPED);
    using WritePipeFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR, PUCHAR, UINT, PUINT, LPOVERLAPPED);
    using PipeFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR);
    using GetOverlappedResultFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, LPOVERLAPPED, PUINT, BOOL);
    using RegisterIsochBufferFn = BOOL (WINAPI*)(WINUSB_INTERFACE_HANDLE, UCHAR, PUCHAR, ULONG, PWINUSB_ISOCH_BUFFER_HANDLE);
    using UnregisterIsochBufferFn = BOOL (WINAPI*)(WINUSB_ISOCH_BUFFER_HANDLE);
    using ReadIsochPipeAsapFn = BOOL (WINAPI*)(WINUSB_ISOCH_BUFFER_HANDLE, ULONG, ULONG, BOOL, ULONG, PUSBD_ISO_PACKET_DESCRIPTOR, LPOVERLAPPED);
    using WriteIsochPipeAsapFn = BOOL (WINAPI*)(WINUSB_ISOCH_BUFFER_HANDLE, ULONG, ULONG, BOOL, LPOVERLAPPED);

    Api() = default;
    Api(const Api&) = delete;
    Api& operator=(const Api&) = delete;

    static BOOL FailBool() { SetLastError(ERROR_PROC_NOT_FOUND); return FALSE; }

    template <typename T>
    bool ResolveRequired(T& target, const char* name) {
        target = reinterpret_cast<T>(GetProcAddress(m_module, name));
        if (target) return true;
        m_loadError = ERROR_PROC_NOT_FOUND;
        return false;
    }

    template <typename T>
    void ResolveOptional(T& target, const char* name) {
        target = reinterpret_cast<T>(GetProcAddress(m_module, name));
    }

    bool ValidateIsoTransfer(const IsoBufferRegistration* registration, ULONG offset, UINT length,
                             const IsoContext* context) const {
        if (!registration || !registration->handle || !registration->buffer || !registration->length ||
            !context || !length || context->packetCount <= 0 || context->packetBytes <= 0) {
            SetLastError(ERROR_INVALID_PARAMETER); return false;
        }
        const ULONGLONG expected = static_cast<ULONGLONG>(context->packetCount) *
                                   static_cast<ULONGLONG>(context->packetBytes);
        if (expected != length || offset > registration->length ||
            length > registration->length - offset) {
            SetLastError(ERROR_INVALID_DATA); return false;
        }
        return true;
    }

    void Load() {
        m_module = LoadLibraryExW(L"winusb.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!m_module) { m_loadError = GetLastError(); return; }
        bool ok = true;
#define REMOLD_WINUSB_REQUIRED(member, symbol) ok = ResolveRequired(member, symbol) && ok
        REMOLD_WINUSB_REQUIRED(m_initialize, "WinUsb_Initialize");
        REMOLD_WINUSB_REQUIRED(m_free, "WinUsb_Free");
        REMOLD_WINUSB_REQUIRED(m_getAssociatedInterface, "WinUsb_GetAssociatedInterface");
        REMOLD_WINUSB_REQUIRED(m_queryInterfaceSettings, "WinUsb_QueryInterfaceSettings");
        REMOLD_WINUSB_REQUIRED(m_queryDeviceInformation, "WinUsb_QueryDeviceInformation");
        REMOLD_WINUSB_REQUIRED(m_getDescriptor, "WinUsb_GetDescriptor");
        REMOLD_WINUSB_REQUIRED(m_setCurrentAlternateSetting, "WinUsb_SetCurrentAlternateSetting");
        REMOLD_WINUSB_REQUIRED(m_queryPipe, "WinUsb_QueryPipe");
        REMOLD_WINUSB_REQUIRED(m_controlTransfer, "WinUsb_ControlTransfer");
        REMOLD_WINUSB_REQUIRED(m_readPipe, "WinUsb_ReadPipe");
        REMOLD_WINUSB_REQUIRED(m_writePipe, "WinUsb_WritePipe");
        REMOLD_WINUSB_REQUIRED(m_resetPipe, "WinUsb_ResetPipe");
        REMOLD_WINUSB_REQUIRED(m_abortPipe, "WinUsb_AbortPipe");
        REMOLD_WINUSB_REQUIRED(m_flushPipe, "WinUsb_FlushPipe");
        REMOLD_WINUSB_REQUIRED(m_getOverlappedResult, "WinUsb_GetOverlappedResult");
        REMOLD_WINUSB_REQUIRED(m_registerIsochBuffer, "WinUsb_RegisterIsochBuffer");
        REMOLD_WINUSB_REQUIRED(m_unregisterIsochBuffer, "WinUsb_UnregisterIsochBuffer");
        REMOLD_WINUSB_REQUIRED(m_readIsochPipeAsap, "WinUsb_ReadIsochPipeAsap");
        REMOLD_WINUSB_REQUIRED(m_writeIsochPipeAsap, "WinUsb_WriteIsochPipeAsap");
#undef REMOLD_WINUSB_REQUIRED
        ResolveOptional(m_queryPipeEx, "WinUsb_QueryPipeEx");
        if (!ok) return;
        m_ready = true;
        m_loadError = ERROR_SUCCESS;
    }

    HMODULE m_module = nullptr;
    std::once_flag m_once;
    bool m_ready = false;
    DWORD m_loadError = ERROR_SUCCESS;
    InitializeFn m_initialize = nullptr;
    FreeFn m_free = nullptr;
    GetAssociatedInterfaceFn m_getAssociatedInterface = nullptr;
    QueryInterfaceSettingsFn m_queryInterfaceSettings = nullptr;
    QueryDeviceInformationFn m_queryDeviceInformation = nullptr;
    GetDescriptorFn m_getDescriptor = nullptr;
    SetCurrentAlternateSettingFn m_setCurrentAlternateSetting = nullptr;
    QueryPipeFn m_queryPipe = nullptr;
    QueryPipeExFn m_queryPipeEx = nullptr;
    ControlTransferFn m_controlTransfer = nullptr;
    ReadPipeFn m_readPipe = nullptr;
    WritePipeFn m_writePipe = nullptr;
    PipeFn m_resetPipe = nullptr;
    PipeFn m_abortPipe = nullptr;
    PipeFn m_flushPipe = nullptr;
    GetOverlappedResultFn m_getOverlappedResult = nullptr;
    RegisterIsochBufferFn m_registerIsochBuffer = nullptr;
    UnregisterIsochBufferFn m_unregisterIsochBuffer = nullptr;
    ReadIsochPipeAsapFn m_readIsochPipeAsap = nullptr;
    WriteIsochPipeAsapFn m_writeIsochPipeAsap = nullptr;
};

inline Api& Get() { return Api::Instance(); }
inline bool Ready() { return Get().EnsureLoaded(); }

} // namespace Kinect360RemoldWinUsb
