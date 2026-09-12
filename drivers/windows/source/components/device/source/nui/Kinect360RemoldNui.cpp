#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include "Kinect360RemoldControlProtocol.h"

namespace {
using Kinect360RemoldControl::Command;
using Kinect360RemoldControl::Reply;
using Kinect360RemoldControl::Request;

struct BrokerPipe {
    HANDLE handle = INVALID_HANDLE_VALUE;
    ~BrokerPipe() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
};

int Usage() {
    std::puts(
        "Kinect360RemoldNui broker-status | status | tilt <deg> | "
        "led <off|green|red|yellow|blink-green|blink-yellow-red>");
    return 2;
}

HRESULT LastHr() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

HRESULT OpenControlPipe(BrokerPipe& pipe) {
    // Every hardware revision is controlled through the same broker contract.
    // 1414/1473 USB topology is intentionally invisible to this client.
    constexpr DWORD kOpenAttempts = 4;
    HRESULT last = HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
    for (DWORD attempt = 0; attempt < kOpenAttempts; ++attempt) {
        if (!WaitNamedPipeW(Kinect360RemoldControl::kPipeName, 350)) {
            last = LastHr();
            continue;
        }
        pipe.handle = CreateFileW(Kinect360RemoldControl::kPipeName,
                                  GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (pipe.handle == INVALID_HANDLE_VALUE) {
            last = LastHr();
            continue;
        }
        DWORD mode = PIPE_READMODE_MESSAGE;
        if (!SetNamedPipeHandleState(pipe.handle, &mode, nullptr, nullptr)) {
            last = LastHr();
            CloseHandle(pipe.handle);
            pipe.handle = INVALID_HANDLE_VALUE;
            continue;
        }
        return S_OK;
    }
    return last;
}

HRESULT BrokerExchange(Command command, int32_t value, Reply& reply) {
    BrokerPipe pipe;
    const HRESULT openHr = OpenControlPipe(pipe);
    if (FAILED(openHr)) return openHr;

    Request request{};
    request.command = command;
    request.value = value;
    DWORD written = 0;
    if (!WriteFile(pipe.handle, &request, sizeof(request), &written, nullptr) || written != sizeof(request))
        return LastHr();
    DWORD read = 0;
    if (!ReadFile(pipe.handle, &reply, sizeof(reply), &read, nullptr) || read != sizeof(reply))
        return LastHr();
    if (reply.magic != Kinect360RemoldControl::kMagic || reply.version != Kinect360RemoldControl::kVersion)
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    return static_cast<HRESULT>(reply.result);
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
        std::printf("OK broker=ready\n");
    } else {
        std::printf("OK device=KinectXbox360 transport=broker accel=%d,%d,%d tilt=%.1f state=%u\n",
                    reply.accelX, reply.accelY, reply.accelZ,
                    static_cast<double>(reply.tiltTenths) / 10.0,
                    static_cast<unsigned int>(reply.state));
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
    std::printf("OK device=KinectXbox360 transport=broker requested=%ld actual=%.1f verified=1\n",
                value, static_cast<double>(reply.tiltTenths) / 10.0);
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
    std::printf("OK device=KinectXbox360 transport=broker led=%d\n", state);
    return 0;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) return Usage();
    if (_wcsicmp(argv[1], L"broker-status") == 0 && argc == 2) return BrokerStatus(true);
    if (_wcsicmp(argv[1], L"status") == 0 && argc == 2) return BrokerStatus(false);
    if (_wcsicmp(argv[1], L"tilt") == 0 && argc == 3) return BrokerTilt(argv[2]);
    if (_wcsicmp(argv[1], L"led") == 0 && argc == 3) return BrokerLed(argv[2]);
    return Usage();
}
