#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <wincodec.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shlobj.h>
#include <wincrypt.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "Kinect360RemoldFrameTransport.h"

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ws2_32.lib")

namespace Frame = Kinect360RemoldFrameTransport;

namespace {
constexpr wchar_t kServiceName[] = L"Kinect360RemoldCameraIp";
constexpr wchar_t kProductFolder[] = L"Kinect Xbox 360 Remold";
constexpr wchar_t kConfigName[] = L"camera-ip.ini";
constexpr wchar_t kLogName[] = L"camera-ip.log";
constexpr DWORD kFramePollMs = 8;
constexpr DWORD kMappingRetryMs = 500;
constexpr DWORD kClientIoTimeoutMs = 3000;
constexpr size_t kMaxRequestBytes = 16u * 1024u;

SERVICE_STATUS_HANDLE g_statusHandle = nullptr;
SERVICE_STATUS g_status{};
HANDLE g_stopEvent = nullptr;
std::atomic<bool> g_running{true};
std::atomic<SOCKET> g_listener{INVALID_SOCKET};
std::atomic<DWORD> g_runtimeError{ERROR_SUCCESS};

struct Config {
    bool enabled = true;
    std::string bindAddress;
    uint16_t port = 0;
    std::string user;
    std::string password;
    uint32_t fps = 0;
    uint32_t jpegQuality = 0;
    uint32_t maxClients = 0;
};

struct LatestJpeg {
    std::mutex lock;
    std::shared_ptr<const std::vector<uint8_t>> bytes;
    uint64_t frameNumber = 0;
    uint64_t sourceTickMs = 0;
    uint64_t encodedTickMs = 0;
};

LatestJpeg g_latest;
std::atomic<bool> g_sourceOnline{false};
std::atomic<uint64_t> g_lastSourceFrame{0};
std::atomic<uint64_t> g_lastSourceTick{0};
std::atomic<uint32_t> g_activeClients{0};
std::atomic<uint32_t> g_authenticatedClients{0};
Config g_config;

void SetServiceState(DWORD state, DWORD win32 = NO_ERROR, DWORD hint = 0);

std::wstring ProgramDataFolder() {
    wchar_t path[MAX_PATH]{};
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, SHGFP_TYPE_CURRENT, path))) return L"";
    std::wstring folder(path);
    folder += L"\\";
    folder += kProductFolder;
    return folder;
}

std::wstring ConfigPath() { const auto base = ProgramDataFolder(); return base.empty() ? L"" : base + L"\\" + kConfigName; }
std::wstring LogPath() { const auto base = ProgramDataFolder(); return base.empty() ? L"" : base + L"\\" + kLogName; }

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int chars = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (chars <= 0) return {};
    std::string out(static_cast<size_t>(chars), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), out.data(), chars, nullptr, nullptr);
    return out;
}

void EnsureDirectory() {
    const std::wstring folder = ProgramDataFolder();
    if (folder.empty()) return;
    (void)CreateDirectoryW(folder.c_str(), nullptr);
}

void Log(const std::string& line) {
    EnsureDirectory();
    const std::wstring path = LogPath();
    if (path.empty()) return;
    HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME st{}; GetLocalTime(&st);
    char prefix[96]{};
    const int n = std::snprintf(prefix, sizeof(prefix), "%04u-%02u-%02u %02u:%02u:%02u.%03u ",
        static_cast<unsigned>(st.wYear), static_cast<unsigned>(st.wMonth), static_cast<unsigned>(st.wDay),
        static_cast<unsigned>(st.wHour), static_cast<unsigned>(st.wMinute), static_cast<unsigned>(st.wSecond),
        static_cast<unsigned>(st.wMilliseconds));
    DWORD written = 0;
    if (n > 0) (void)WriteFile(file, prefix, static_cast<DWORD>(n), &written, nullptr);
    (void)WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
    static const char crlf[] = "\r\n";
    (void)WriteFile(file, crlf, 2, &written, nullptr);
    CloseHandle(file);
}

std::string Trim(std::string value) {
    auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), notSpace));
    value.erase(std::find_if(value.rbegin(), value.rend(), notSpace).base(), value.end());
    return value;
}

bool ParseUnsigned(const std::string& text, uint32_t minValue, uint32_t maxValue, uint32_t& out) {
    if (text.empty()) return false;
    char* end = nullptr;
    errno = 0;
    const unsigned long value = std::strtoul(text.c_str(), &end, 10);
    if (errno || !end || *end != '\0' || value < minValue || value > maxValue) return false;
    out = static_cast<uint32_t>(value);
    return true;
}

bool LoadConfig(Config& cfg, std::string& error) {
    const std::wstring path = ConfigPath();
    if (path.empty()) { error = "ProgramData path unavailable"; return false; }
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) { error = "camera-ip.ini not found; run installer"; return false; }
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 || size.QuadPart > 1024 * 1024) {
        CloseHandle(file); error = "invalid camera-ip.ini size"; return false;
    }
    std::string text(static_cast<size_t>(size.QuadPart), '\0');
    DWORD read = 0;
    const BOOL ok = ReadFile(file, text.data(), static_cast<DWORD>(text.size()), &read, nullptr);
    CloseHandle(file);
    if (!ok || read != static_cast<DWORD>(text.size())) { error = "could not read camera-ip.ini"; return false; }

    Config next{};
    std::istringstream stream(text);
    std::string line;
    while (std::getline(stream, line)) {
        line = Trim(line);
        if (line.empty() || line[0] == '#' || line[0] == ';') continue;
        const size_t equals = line.find('=');
        if (equals == std::string::npos) continue;
        const std::string key = Trim(line.substr(0, equals));
        const std::string value = Trim(line.substr(equals + 1));
        if (key == "enabled") next.enabled = (_stricmp(value.c_str(), "true") == 0 || value == "1");
        else if (key == "bind") next.bindAddress = value;
        else if (key == "port") { uint32_t v=0; if (!ParseUnsigned(value,1,65535,v)) { error="invalid port"; return false; } next.port=static_cast<uint16_t>(v); }
        else if (key == "user") next.user = value;
        else if (key == "password") next.password = value;
        else if (key == "fps") { uint32_t v=0; if (!ParseUnsigned(value,1,30,v)) { error="invalid fps"; return false; } next.fps=v; }
        else if (key == "jpegQuality") { uint32_t v=0; if (!ParseUnsigned(value,25,95,v)) { error="invalid jpegQuality"; return false; } next.jpegQuality=v; }
        else if (key == "maxClients") { uint32_t v=0; if (!ParseUnsigned(value,1,32,v)) { error="invalid maxClients"; return false; } next.maxClients=v; }
    }
    if (next.bindAddress.empty() || next.port == 0 || next.user.empty() || next.password.empty() ||
        next.password == "auto" || next.fps == 0 || next.jpegQuality == 0 || next.maxClients == 0) {
        error = "camera-ip.ini is incomplete"; return false;
    }
    cfg = std::move(next);
    return true;
}

std::string GeneratePassword() {
    uint8_t random[24]{};
    if (BCryptGenRandom(nullptr, random, static_cast<ULONG>(sizeof(random)), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) return {};
    DWORD chars = 0;
    if (!CryptBinaryToStringA(random, static_cast<DWORD>(sizeof(random)), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &chars) || chars == 0) return {};
    std::string text(chars, '\0');
    if (!CryptBinaryToStringA(random, static_cast<DWORD>(sizeof(random)), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, text.data(), &chars)) return {};
    if (!text.empty() && text.back() == '\0') text.pop_back();
    for (char& c : text) { if (c == '+') c = '-'; else if (c == '/') c = '_'; }
    while (!text.empty() && text.back() == '=') text.pop_back();
    return text;
}

bool WriteConfigSecure(const Config& cfg, std::string& error) {
    EnsureDirectory();
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
        L"D:P(A;;FA;;;SY)(A;;FA;;;BA)", SDDL_REVISION_1, &sd, nullptr)) {
        error = "could not build config ACL"; return false;
    }
    SECURITY_ATTRIBUTES sa{sizeof(sa), sd, FALSE};
    const std::wstring path = ConfigPath();
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, &sa, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED, nullptr);
    LocalFree(sd);
    if (file == INVALID_HANDLE_VALUE) { error = "could not create camera-ip.ini"; return false; }
    std::ostringstream text;
    text << "# Kinect Xbox 360 Remold - native IP camera runtime\r\n"
         << "# The password is generated, never compiled into the driver/runtime.\r\n"
         << "enabled=" << (cfg.enabled ? "true" : "false") << "\r\n"
         << "bind=" << cfg.bindAddress << "\r\n"
         << "port=" << cfg.port << "\r\n"
         << "user=" << cfg.user << "\r\n"
         << "password=" << cfg.password << "\r\n"
         << "fps=" << cfg.fps << "\r\n"
         << "jpegQuality=" << cfg.jpegQuality << "\r\n"
         << "maxClients=" << cfg.maxClients << "\r\n";
    const std::string body = text.str();
    DWORD written = 0;
    const BOOL ok = WriteFile(file, body.data(), static_cast<DWORD>(body.size()), &written, nullptr);
    FlushFileBuffers(file);
    CloseHandle(file);
    if (!ok || written != static_cast<DWORD>(body.size())) { error = "could not write camera-ip.ini"; return false; }
    return true;
}

bool ConstantTimeEqual(const std::string& a, const std::string& b) {
    const size_t n = std::max(a.size(), b.size());
    unsigned diff = static_cast<unsigned>(a.size() ^ b.size());
    for (size_t i=0;i<n;++i) {
        const unsigned char av = i < a.size() ? static_cast<unsigned char>(a[i]) : 0;
        const unsigned char bv = i < b.size() ? static_cast<unsigned char>(b[i]) : 0;
        diff |= static_cast<unsigned>(av ^ bv);
    }
    return diff == 0;
}

std::string ExpectedBasic(const Config& cfg) {
    const std::string plain = cfg.user + ":" + cfg.password;
    DWORD chars = 0;
    if (!CryptBinaryToStringA(reinterpret_cast<const BYTE*>(plain.data()), static_cast<DWORD>(plain.size()),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &chars) || chars == 0) return {};
    std::string encoded(chars, '\0');
    if (!CryptBinaryToStringA(reinterpret_cast<const BYTE*>(plain.data()), static_cast<DWORD>(plain.size()),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, encoded.data(), &chars)) return {};
    if (!encoded.empty() && encoded.back() == '\0') encoded.pop_back();
    return "Basic " + encoded;
}

void Nv12ToBgr(const uint8_t* nv12, std::vector<uint8_t>& bgr) {
    const int width = static_cast<int>(Frame::kWidth);
    const int height = static_cast<int>(Frame::kHeight);
    bgr.resize(static_cast<size_t>(width) * height * 3u);
    const uint8_t* yPlane = nv12;
    const uint8_t* uvPlane = nv12 + static_cast<size_t>(width) * height;
    auto clamp = [](int v) -> uint8_t { return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v)); };
    for (int y=0;y<height;++y) {
        const uint8_t* yRow = yPlane + static_cast<size_t>(y) * width;
        const uint8_t* uvRow = uvPlane + static_cast<size_t>(y / 2) * width;
        uint8_t* dst = bgr.data() + static_cast<size_t>(y) * width * 3u;
        for (int x=0;x<width;++x) {
            const int Y = static_cast<int>(yRow[x]);
            const int U = static_cast<int>(uvRow[x & ~1]) - 128;
            const int V = static_cast<int>(uvRow[(x & ~1) + 1]) - 128;
            const int C = std::max(0, Y - 16);
            const int R = (298 * C + 409 * V + 128) >> 8;
            const int G = (298 * C - 100 * U - 208 * V + 128) >> 8;
            const int B = (298 * C + 516 * U + 128) >> 8;
            dst[x*3+0] = clamp(B); dst[x*3+1] = clamp(G); dst[x*3+2] = clamp(R);
        }
    }
}

bool EncodeJpegWic(IWICImagingFactory* factory, const std::vector<uint8_t>& bgr, uint32_t quality, std::vector<uint8_t>& jpeg) {
    if (!factory || bgr.size() != static_cast<size_t>(Frame::kWidth) * Frame::kHeight * 3u) return false;
    IStream* stream = nullptr;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return false;
    IWICBitmapEncoder* encoder = nullptr;
    IWICBitmapFrameEncode* frame = nullptr;
    IPropertyBag2* props = nullptr;
    bool ok = false;
    if (SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder)) &&
        SUCCEEDED(encoder->Initialize(stream, WICBitmapEncoderNoCache)) &&
        SUCCEEDED(encoder->CreateNewFrame(&frame, &props))) {
        PROPBAG2 option{}; option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
        VARIANT value{}; VariantInit(&value); value.vt = VT_R4; value.fltVal = std::clamp(quality / 100.0f, 0.25f, 0.95f);
        if (props) (void)props->Write(1, &option, &value);
        VariantClear(&value);
        WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
        const UINT stride = Frame::kWidth * 3u;
        if (SUCCEEDED(frame->Initialize(props)) &&
            SUCCEEDED(frame->SetSize(Frame::kWidth, Frame::kHeight)) &&
            SUCCEEDED(frame->SetPixelFormat(&format)) &&
            IsEqualGUID(format, GUID_WICPixelFormat24bppBGR) &&
            SUCCEEDED(frame->WritePixels(Frame::kHeight, stride, static_cast<UINT>(bgr.size()), const_cast<BYTE*>(bgr.data()))) &&
            SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit())) {
            HGLOBAL global = nullptr; STATSTG stat{};
            if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME)) && stat.cbSize.QuadPart > 0 &&
                stat.cbSize.QuadPart <= 16ll * 1024ll * 1024ll &&
                SUCCEEDED(GetHGlobalFromStream(stream, &global)) && global) {
                const SIZE_T bytes = static_cast<SIZE_T>(stat.cbSize.QuadPart);
                const void* data = GlobalLock(global);
                if (data) {
                    jpeg.assign(static_cast<const uint8_t*>(data), static_cast<const uint8_t*>(data) + bytes);
                    ok = true;
                    GlobalUnlock(global);
                }
            }
        }
    }
    if (props) props->Release();
    if (frame) frame->Release();
    if (encoder) encoder->Release();
    stream->Release();
    return ok;
}

void ResizeNv12ToVga(const uint8_t* source, uint32_t sourceWidth, uint32_t sourceHeight,
                     std::vector<uint8_t>& target) {
    target.resize(Frame::kNv12Bytes);
    const uint8_t* sy = source;
    const uint8_t* suv = source + static_cast<size_t>(sourceWidth) * sourceHeight;
    uint8_t* dy = target.data();
    uint8_t* duv = target.data() + static_cast<size_t>(Frame::kWidth) * Frame::kHeight;
    for (uint32_t y=0;y<Frame::kHeight;++y) {
        const uint32_t yy=std::min(sourceHeight-1u,static_cast<uint32_t>((static_cast<uint64_t>(y)*sourceHeight)/Frame::kHeight));
        for (uint32_t x=0;x<Frame::kWidth;++x) {
            const uint32_t xx=std::min(sourceWidth-1u,static_cast<uint32_t>((static_cast<uint64_t>(x)*sourceWidth)/Frame::kWidth));
            dy[static_cast<size_t>(y)*Frame::kWidth+x]=sy[static_cast<size_t>(yy)*sourceWidth+xx];
        }
    }
    for (uint32_t y=0;y<Frame::kHeight/2u;++y) {
        const uint32_t yy=std::min(sourceHeight/2u-1u,static_cast<uint32_t>((static_cast<uint64_t>(y)*(sourceHeight/2u))/(Frame::kHeight/2u)));
        for (uint32_t x=0;x<Frame::kWidth;x+=2u) {
            uint32_t xx=std::min(sourceWidth-2u,static_cast<uint32_t>((static_cast<uint64_t>(x)*sourceWidth)/Frame::kWidth));
            xx&=~1u;
            const size_t sp=static_cast<size_t>(yy)*sourceWidth+xx;
            const size_t tp=static_cast<size_t>(y)*Frame::kWidth+x;
            duv[tp]=suv[sp];duv[tp+1u]=suv[sp+1u];
        }
    }
}

class FrameReader {
public:
    ~FrameReader() { Close(); }
    bool Open() {
        Close();
        mapping_ = OpenFileMappingW(FILE_MAP_READ, FALSE, Frame::kMappingName);
        if (!mapping_) return false;
        base_ = MapViewOfFile(mapping_, FILE_MAP_READ, 0, 0, Frame::kMappingBytes);
        if (!base_) { Close(); return false; }
        header_ = static_cast<const Frame::SharedHeader*>(base_);
        if (header_->magic != Frame::kMagic || header_->version != Frame::kVersion ||
            header_->fourcc != Frame::kNv12Fourcc || header_->slotCount != Frame::kSlotCount) {
            Close(); return false;
        }
        return true;
    }
    bool Read(std::vector<uint8_t>& nv12, uint64_t& frameNumber, uint64_t& tickMs, bool& online) {
        if (!header_ || !base_) return false;
        for (int attempt=0;attempt<4;++attempt) {
            const LONG before = header_->colorSequence;
            if (before & 1) { YieldProcessor(); continue; }
            MemoryBarrier();
            const LONG slotRaw = header_->activeSlot;
            const LONG onlineRaw = header_->online;
            const uint32_t sourceWidth = header_->width;
            const uint32_t sourceHeight = header_->height;
            const uint32_t sourceBytes = header_->frameBytes;
            if (slotRaw < 0 || static_cast<uint32_t>(slotRaw) >= Frame::kSlotCount) return false;
            if ((sourceWidth != Frame::kWidth && sourceWidth != Frame::kHqWidth) ||
                (sourceHeight != Frame::kHeight && sourceHeight != Frame::kHqHeight) ||
                sourceBytes != sourceWidth * sourceHeight * 3u / 2u || sourceBytes > Frame::kHqNv12Bytes) return false;
            const uint32_t slot = static_cast<uint32_t>(slotRaw);
            const Frame::FrameSlotMeta meta = header_->slot[slot];
            if (meta.bytes != sourceBytes) { online = onlineRaw != 0; return false; }
            std::vector<uint8_t> source(sourceBytes);
            std::memcpy(source.data(), Frame::SlotAddress(base_, slot), sourceBytes);
            MemoryBarrier();
            const LONG after = header_->colorSequence;
            if (before == after && !(after & 1)) {
                if (sourceWidth == Frame::kWidth && sourceHeight == Frame::kHeight) nv12 = std::move(source);
                else ResizeNv12ToVga(source.data(), sourceWidth, sourceHeight, nv12);
                frameNumber = meta.frameNumber; tickMs = meta.tickMs; online = onlineRaw != 0; return true;
            }
        }
        return false;
    }
private:
    HANDLE mapping_ = nullptr;
    const void* base_ = nullptr;
    const Frame::SharedHeader* header_ = nullptr;
    void Close() {
        if (base_) UnmapViewOfFile(base_);
        if (mapping_) CloseHandle(mapping_);
        base_ = nullptr; mapping_ = nullptr; header_ = nullptr;
    }
};

void EncoderLoop() {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IWICImagingFactory* factory = nullptr;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
        Log("encoder: WIC factory unavailable"); g_runtimeError.store(ERROR_NOT_SUPPORTED); g_sourceOnline.store(false);
        if (g_stopEvent) SetEvent(g_stopEvent); if (SUCCEEDED(co)) CoUninitialize(); return;
    }
    FrameReader reader;
    std::vector<uint8_t> nv12, bgr, jpeg;
    uint64_t lastFrame = 0;
    uint64_t nextEncode = 0;
    const uint64_t minInterval = std::max<uint64_t>(1, 1000u / g_config.fps);
    while (g_running.load()) {
        if (!reader.Open()) {
            g_sourceOnline.store(false);
            if (WaitForSingleObject(g_stopEvent, kMappingRetryMs) == WAIT_OBJECT_0) break;
            continue;
        }
        Log("encoder: shared RGB transport connected");
        while (g_running.load()) {
            uint64_t frameNumber=0, tickMs=0; bool online=false;
            if (reader.Read(nv12, frameNumber, tickMs, online)) {
                g_sourceOnline.store(online);
                g_lastSourceFrame.store(frameNumber);
                g_lastSourceTick.store(tickMs);
                const uint64_t now = GetTickCount64();
                if (online && frameNumber != 0 && frameNumber != lastFrame && now >= nextEncode) {
                    lastFrame = frameNumber; nextEncode = now + minInterval;
                    Nv12ToBgr(nv12.data(), bgr);
                    jpeg.clear();
                    if (EncodeJpegWic(factory, bgr, g_config.jpegQuality, jpeg)) {
                        auto published = std::make_shared<const std::vector<uint8_t>>(std::move(jpeg));
                        std::lock_guard<std::mutex> guard(g_latest.lock);
                        g_latest.bytes = std::move(published); g_latest.frameNumber = frameNumber;
                        g_latest.sourceTickMs = tickMs; g_latest.encodedTickMs = now;
                    }
                }
            }
            if (WaitForSingleObject(g_stopEvent, kFramePollMs) == WAIT_OBJECT_0) break;
            if (!online && GetTickCount64() - g_lastSourceTick.load() > 3000) break;
        }
    }
    factory->Release();
    if (SUCCEEDED(co)) CoUninitialize();
}

bool SendAll(SOCKET s, const void* data, size_t bytes) {
    const char* p = static_cast<const char*>(data);
    while (bytes && g_running.load()) {
        const int chunk = static_cast<int>(std::min<size_t>(bytes, 1u << 20));
        const int sent = send(s, p, chunk, 0);
        if (sent <= 0) return false;
        p += sent; bytes -= static_cast<size_t>(sent);
    }
    return bytes == 0;
}

bool SendText(SOCKET s, const std::string& text) { return SendAll(s, text.data(), text.size()); }

std::string HeaderValue(const std::string& request, const std::string& name) {
    size_t pos = request.find("\r\n");
    while (pos != std::string::npos && pos + 2 < request.size()) {
        const size_t next = request.find("\r\n", pos + 2);
        const size_t begin = pos + 2;
        if (next == std::string::npos || next == begin) break;
        const std::string line = request.substr(begin, next - begin);
        const size_t colon = line.find(':');
        if (colon != std::string::npos) {
            std::string key = Trim(line.substr(0, colon));
            if (_stricmp(key.c_str(), name.c_str()) == 0) return Trim(line.substr(colon + 1));
        }
        pos = next;
    }
    return {};
}

bool Authorized(const std::string& request) {
    const std::string got = HeaderValue(request, "Authorization");
    const std::string expected = ExpectedBasic(g_config);
    return !got.empty() && !expected.empty() && ConstantTimeEqual(got, expected);
}

void SendUnauthorized(SOCKET s) {
    static const char response[] =
        "HTTP/1.1 401 Unauthorized\r\n"
        "WWW-Authenticate: Basic realm=\"Kinect Xbox 360 Remold\"\r\n"
        "Cache-Control: no-store\r\nContent-Type: text/plain; charset=utf-8\r\n"
        "Content-Length: 23\r\nConnection: close\r\n\r\nAuthentication required";
    (void)SendAll(s, response, sizeof(response)-1);
}

std::shared_ptr<const std::vector<uint8_t>> Latest(uint64_t& frameNumber, uint64_t& sourceTick, uint64_t& encodedTick) {
    std::lock_guard<std::mutex> guard(g_latest.lock);
    frameNumber = g_latest.frameNumber; sourceTick = g_latest.sourceTickMs; encodedTick = g_latest.encodedTickMs;
    return g_latest.bytes;
}

void SendServiceUnavailable(SOCKET s) {
    static const char body[] = "RGB source unavailable";
    std::ostringstream h;
    h << "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\nCache-Control: no-store\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: "
      << (sizeof(body)-1) << "\r\nConnection: close\r\n\r\n";
    (void)SendText(s,h.str()); (void)SendAll(s,body,sizeof(body)-1);
}

void HandleSnapshot(SOCKET s) {
    uint64_t frame=0, source=0, encoded=0;
    const auto jpg = Latest(frame,source,encoded);
    if (!g_sourceOnline.load() || !jpg || jpg->empty() || GetTickCount64() - encoded > 5000) { SendServiceUnavailable(s); return; }
    std::ostringstream h;
    h << "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nCache-Control: no-store, no-cache, must-revalidate\r\nContent-Length: " << jpg->size()
      << "\r\nX-Kinect-Frame: " << frame << "\r\nX-Kinect-Source-Tick: " << source << "\r\nConnection: close\r\n\r\n";
    if (SendText(s,h.str())) (void)SendAll(s,jpg->data(),jpg->size());
}

void HandleRoot(SOCKET s) {
    static const char body[] =
        "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<title>Kinect Xbox 360 Remold</title></head><body style='margin:0;background:#111;color:#eee;font-family:Segoe UI,sans-serif'>"
        "<main style='max-width:1000px;margin:auto;padding:18px'><h1>Kinect Xbox 360 Remold</h1>"
        "<p>Native driver-runtime IP camera. RGB is read from the same shared frame transport used by the Windows virtual camera.</p>"
        "<img src='/stream.mjpg' style='display:block;width:100%;height:auto;background:#000' alt='Kinect camera stream'>"
        "<p><a style='color:#9cf' href='/snapshot.jpg'>Snapshot</a> &middot; <a style='color:#9cf' href='/status.json'>Status JSON</a></p></main></body></html>";
    std::ostringstream h;
    h << "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: " << (sizeof(body)-1)
      << "\r\nConnection: close\r\n\r\n";
    if (SendText(s,h.str())) (void)SendAll(s,body,sizeof(body)-1);
}

void HandleStatus(SOCKET s) {
    uint64_t frame=0, source=0, encoded=0; const auto jpg=Latest(frame,source,encoded);
    const uint64_t now=GetTickCount64();
    const bool online=g_sourceOnline.load();
    const bool stale=!jpg || encoded==0 || now-encoded>5000;
    std::ostringstream body;
    body << "{\"version\":1,\"component\":\"Kinect360RemoldCameraIp\",\"transport\":\"Global\\\\Kinect360RemoldFrame\","
         << "\"rgbOnline\":" << (online?"true":"false") << ",\"stale\":" << (stale?"true":"false")
         << ",\"frame\":" << frame << ",\"sourceTickMs\":" << source << ",\"encodedTickMs\":" << encoded
         << ",\"clients\":" << g_activeClients.load() << ",\"authenticatedClients\":" << g_authenticatedClients.load() << "}";
    const std::string data=body.str();
    std::ostringstream h; h << "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: " << data.size() << "\r\nConnection: close\r\n\r\n";
    if(SendText(s,h.str())) (void)SendAll(s,data.data(),data.size());
}

void HandleStream(SOCKET s) {
    static constexpr char boundary[]="kinectremoldframe";
    if(!SendText(s,"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=kinectremoldframe\r\nCache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\n\r\n")) return;
    uint64_t last=0;
    const uint64_t interval=std::max<uint64_t>(1,1000u/g_config.fps);
    while(g_running.load()) {
        uint64_t frame=0,source=0,encoded=0; const auto jpg=Latest(frame,source,encoded);
        if(g_sourceOnline.load() && jpg && !jpg->empty() && frame!=last && GetTickCount64()-encoded<=5000) {
            last=frame;
            std::ostringstream h;
            h << "--" << boundary << "\r\nContent-Type: image/jpeg\r\nContent-Length: " << jpg->size() << "\r\nX-Kinect-Frame: " << frame << "\r\nX-Kinect-Source-Tick: " << source << "\r\n\r\n";
            if(!SendText(s,h.str()) || !SendAll(s,jpg->data(),jpg->size()) || !SendText(s,"\r\n")) break;
        }
        if(WaitForSingleObject(g_stopEvent,static_cast<DWORD>(interval))==WAIT_OBJECT_0) break;
    }
}

void ClientThread(SOCKET s) {
    DWORD timeout=kClientIoTimeoutMs;
    setsockopt(s,SOL_SOCKET,SO_RCVTIMEO,reinterpret_cast<const char*>(&timeout),static_cast<int>(sizeof(timeout)));
    setsockopt(s,SOL_SOCKET,SO_SNDTIMEO,reinterpret_cast<const char*>(&timeout),static_cast<int>(sizeof(timeout)));
    std::string request; request.reserve(2048); char buffer[2048];
    while(request.size()<kMaxRequestBytes) {
        const int got=recv(s,buffer,static_cast<int>(sizeof(buffer)),0); if(got<=0) break;
        request.append(buffer,buffer+got); if(request.find("\r\n\r\n")!=std::string::npos) break;
    }
    if(request.find("\r\n\r\n")!=std::string::npos) {
        std::istringstream first(request); std::string method,path,version; first>>method>>path>>version;
        if(version.rfind("HTTP/",0)!=0) {
            (void)SendText(s,"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        } else if(method!="GET") {
            (void)SendText(s,"HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        } else if(!Authorized(request)) {
            SendUnauthorized(s);
        } else {
            g_authenticatedClients.fetch_add(1, std::memory_order_acq_rel);
            try {
                if(path=="/" || path=="/index.html") HandleRoot(s);
                else if(path=="/snapshot.jpg") HandleSnapshot(s);
                else if(path=="/stream.mjpg") HandleStream(s);
                else if(path=="/status.json") HandleStatus(s);
                else (void)SendText(s,"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } catch (...) {
                Log("client: request handler failed");
            }
            g_authenticatedClients.fetch_sub(1, std::memory_order_acq_rel);
        }
    }
    shutdown(s,SD_BOTH); closesocket(s); g_activeClients.fetch_sub(1);
}

bool OpenListener() {
    addrinfo hints{}; hints.ai_family=AF_INET; hints.ai_socktype=SOCK_STREAM; hints.ai_protocol=IPPROTO_TCP; hints.ai_flags=AI_PASSIVE;
    addrinfo* result=nullptr;
    const std::string port=std::to_string(g_config.port);
    const char* node=(g_config.bindAddress=="0.0.0.0" || g_config.bindAddress=="*")?nullptr:g_config.bindAddress.c_str();
    if(getaddrinfo(node,port.c_str(),&hints,&result)!=0 || !result) return false;
    SOCKET s=socket(result->ai_family,result->ai_socktype,result->ai_protocol);
    if(s==INVALID_SOCKET){freeaddrinfo(result);return false;}
    BOOL exclusive=TRUE; setsockopt(s,SOL_SOCKET,SO_EXCLUSIVEADDRUSE,reinterpret_cast<const char*>(&exclusive),static_cast<int>(sizeof(exclusive)));
    const bool ok=bind(s,result->ai_addr,static_cast<int>(result->ai_addrlen))==0 && listen(s,SOMAXCONN)==0;
    freeaddrinfo(result); if(!ok){closesocket(s);return false;} g_listener.store(s); return true;
}

void ServerLoop() {
    if(!g_config.enabled){Log("server disabled by configuration"); while(g_running.load()&&WaitForSingleObject(g_stopEvent,1000)!=WAIT_OBJECT_0){} return;}
    if(!OpenListener()){const DWORD error=static_cast<DWORD>(WSAGetLastError());Log("server: listen/bind failed error="+std::to_string(error));g_runtimeError.store(error?error:ERROR_ADDRESS_NOT_ASSOCIATED);if(g_stopEvent)SetEvent(g_stopEvent);return;}
    Log("server: listening on "+g_config.bindAddress+":"+std::to_string(g_config.port));
    while(g_running.load()) {
        const SOCKET listener=g_listener.load();
        if(listener==INVALID_SOCKET) break;
        SOCKET client=accept(listener,nullptr,nullptr);
        if(client==INVALID_SOCKET){if(!g_running.load())break;Sleep(20);continue;}
        const uint32_t reserved = g_activeClients.fetch_add(1);
        if(reserved>=g_config.maxClients){
            g_activeClients.fetch_sub(1);
            static const char busy[]="HTTP/1.1 503 Service Unavailable\r\nRetry-After: 2\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            (void)SendAll(client,busy,sizeof(busy)-1);closesocket(client);continue;
        }
        try{std::thread(ClientThread,client).detach();}catch(...){g_activeClients.fetch_sub(1);closesocket(client);}
    }
    const SOCKET listener=g_listener.exchange(INVALID_SOCKET);if(listener!=INVALID_SOCKET)closesocket(listener);
}

void StopRuntime() {
    g_running.store(false);
    if(g_stopEvent) SetEvent(g_stopEvent);
    const SOCKET listener=g_listener.exchange(INVALID_SOCKET);if(listener!=INVALID_SOCKET){shutdown(listener,SD_BOTH);closesocket(listener);}
}

DWORD RunRuntime() {
    std::string error;
    if(!LoadConfig(g_config,error)){Log("config: "+error);return ERROR_INVALID_DATA;}
    WSADATA wsa{}; if(WSAStartup(MAKEWORD(2,2),&wsa)!=0){Log("WSAStartup failed");return ERROR_NETWORK_UNREACHABLE;}
    g_stopEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr); if(!g_stopEvent){const DWORD errorCode=GetLastError();WSACleanup();return errorCode;}
    g_runtimeError.store(ERROR_SUCCESS);g_running.store(true);
    if(g_statusHandle)SetServiceState(SERVICE_RUNNING);
    Log("runtime start");
    std::thread encoder(EncoderLoop);
    std::thread server(ServerLoop);
    WaitForSingleObject(g_stopEvent,INFINITE);
    StopRuntime();
    if(server.joinable())server.join();
    if(encoder.joinable())encoder.join();
    const uint64_t deadline=GetTickCount64()+5000; while(g_activeClients.load()&&GetTickCount64()<deadline)Sleep(25);
    CloseHandle(g_stopEvent);g_stopEvent=nullptr;WSACleanup();g_sourceOnline.store(false);Log("runtime stop");return g_runtimeError.load();
}

void SetServiceState(DWORD state, DWORD win32, DWORD hint) {
    if(!g_statusHandle)return; g_status.dwServiceType=SERVICE_WIN32_OWN_PROCESS; g_status.dwCurrentState=state; g_status.dwWin32ExitCode=win32;
    g_status.dwControlsAccepted=(state==SERVICE_START_PENDING)?0:SERVICE_ACCEPT_STOP|SERVICE_ACCEPT_SHUTDOWN; g_status.dwWaitHint=hint;
    SetServiceStatus(g_statusHandle,&g_status);
}

DWORD WINAPI ServiceControl(DWORD control,DWORD,LPVOID,LPVOID) {
    if(control==SERVICE_CONTROL_STOP||control==SERVICE_CONTROL_SHUTDOWN){SetServiceState(SERVICE_STOP_PENDING,NO_ERROR,5000);StopRuntime();return NO_ERROR;} return NO_ERROR;
}

void WINAPI ServiceMain(DWORD,LPWSTR*) {
    g_statusHandle=RegisterServiceCtrlHandlerExW(kServiceName,ServiceControl,nullptr); if(!g_statusHandle)return;
    SetServiceState(SERVICE_START_PENDING,NO_ERROR,5000);
    const DWORD rc=RunRuntime();
    SetServiceState(SERVICE_STOPPED,rc);
}

std::vector<std::string> LocalIpv4Addresses() {
    std::vector<std::string> out; char host[256]{}; if(gethostname(host,static_cast<int>(sizeof(host)))!=0)return out;
    addrinfo hints{};hints.ai_family=AF_INET;hints.ai_socktype=SOCK_STREAM;addrinfo* result=nullptr;
    if(getaddrinfo(host,nullptr,&hints,&result)!=0)return out;
    for(addrinfo* p=result;p;p=p->ai_next){char text[INET_ADDRSTRLEN]{};auto* a=reinterpret_cast<sockaddr_in*>(p->ai_addr);if(inet_ntop(AF_INET,&a->sin_addr,text,sizeof(text))&&std::strcmp(text,"127.0.0.1")!=0){if(std::find(out.begin(),out.end(),text)==out.end())out.emplace_back(text);}}
    freeaddrinfo(result);return out;
}

int CommandInit(int argc,wchar_t** argv) {
    Config cfg{};
    for(int i=2;i+1<argc;i+=2){const std::wstring k=argv[i],v=argv[i+1];const std::string value=WideToUtf8(v);
        if(k==L"--enabled"){if(_stricmp(value.c_str(),"true")==0||value=="1")cfg.enabled=true;else if(_stricmp(value.c_str(),"false")==0||value=="0")cfg.enabled=false;else return 2;}
        else if(k==L"--bind")cfg.bindAddress=value;else if(k==L"--port"){uint32_t n=0;if(!ParseUnsigned(value,1,65535,n))return 2;cfg.port=static_cast<uint16_t>(n);}else if(k==L"--user")cfg.user=value;
        else if(k==L"--fps"){uint32_t n=0;if(!ParseUnsigned(value,1,30,n))return 2;cfg.fps=n;}else if(k==L"--quality"){uint32_t n=0;if(!ParseUnsigned(value,25,95,n))return 2;cfg.jpegQuality=n;}
        else if(k==L"--max-clients"){uint32_t n=0;if(!ParseUnsigned(value,1,32,n))return 2;cfg.maxClients=n;}else return 2;}
    if(cfg.bindAddress.empty()||!cfg.port||cfg.user.empty()||!cfg.fps||!cfg.jpegQuality||!cfg.maxClients){std::fwprintf(stderr,L"init requires --enabled --bind --port --user --fps --quality --max-clients\n");return 2;}
    Config old{};std::string error;if(LoadConfig(old,error)&&!old.password.empty()&&old.password!="auto")cfg.password=old.password;else cfg.password=GeneratePassword();
    if(cfg.password.empty()){std::fwprintf(stderr,L"Could not generate password.\n");return 3;}
    if(!WriteConfigSecure(cfg,error)){std::fprintf(stderr,"%s\n",error.c_str());return 4;}
    std::printf("OK config=%s user=%s password=%s bind=%s port=%u\n",WideToUtf8(ConfigPath()).c_str(),cfg.user.c_str(),cfg.password.c_str(),cfg.bindAddress.c_str(),static_cast<unsigned>(cfg.port));return 0;
}

int CommandResetPassword() {
    Config cfg{};std::string error;if(!LoadConfig(cfg,error)){std::fprintf(stderr,"%s\n",error.c_str());return 2;}cfg.password=GeneratePassword();if(cfg.password.empty()||!WriteConfigSecure(cfg,error)){std::fprintf(stderr,"%s\n",error.c_str());return 3;}
    std::printf("OK user=%s password=%s\n",cfg.user.c_str(),cfg.password.c_str());return 0;
}

int CommandSetEnabled(bool enabled) {
    Config cfg{}; std::string error;
    if(!LoadConfig(cfg,error)){std::fprintf(stderr,"%s\n",error.c_str());return 2;}
    cfg.enabled=enabled;
    if(!WriteConfigSecure(cfg,error)){std::fprintf(stderr,"%s\n",error.c_str());return 3;}
    std::printf("OK enabled=%s\n",enabled?"true":"false");
    return 0;
}

int CommandStatus() {
    Config cfg{};std::string error;if(!LoadConfig(cfg,error)){std::fprintf(stderr,"NOT READY %s\n",error.c_str());return 2;}
    WSADATA wsa{};const bool haveWsa=WSAStartup(MAKEWORD(2,2),&wsa)==0;
    SC_HANDLE scm=OpenSCManagerW(nullptr,nullptr,SC_MANAGER_CONNECT);SC_HANDLE service=scm?OpenServiceW(scm,kServiceName,SERVICE_QUERY_STATUS):nullptr;SERVICE_STATUS_PROCESS sp{};DWORD bytes=0;
    bool running=service&&QueryServiceStatusEx(service,SC_STATUS_PROCESS_INFO,reinterpret_cast<LPBYTE>(&sp),static_cast<DWORD>(sizeof(sp)),&bytes)&&sp.dwCurrentState==SERVICE_RUNNING;
    if(service)CloseServiceHandle(service);if(scm)CloseServiceHandle(scm);
    std::printf("%s service=%s enabled=%s bind=%s port=%u user=%s password=%s config=%s\n",running?"OK":"NOT READY",running?"running":"stopped",cfg.enabled?"true":"false",cfg.bindAddress.c_str(),static_cast<unsigned>(cfg.port),cfg.user.c_str(),cfg.password.c_str(),WideToUtf8(ConfigPath()).c_str());
    if(haveWsa){if(cfg.bindAddress=="0.0.0.0"||cfg.bindAddress=="*"){for(const auto& ip:LocalIpv4Addresses())std::printf("URL http://%s:%u/\n",ip.c_str(),static_cast<unsigned>(cfg.port));}else std::printf("URL http://%s:%u/\n",cfg.bindAddress.c_str(),static_cast<unsigned>(cfg.port));WSACleanup();}
    return running?0:1;
}
}

int wmain(int argc,wchar_t** argv) {
    if(argc>=2){const std::wstring cmd=argv[1];if(cmd==L"--console")return static_cast<int>(RunRuntime());if(cmd==L"init")return CommandInit(argc,argv);if(cmd==L"reset-password")return CommandResetPassword();if(cmd==L"enable")return CommandSetEnabled(true);if(cmd==L"disable")return CommandSetEnabled(false);if(cmd==L"status")return CommandStatus();}
    SERVICE_TABLE_ENTRYW table[]={{const_cast<LPWSTR>(kServiceName),ServiceMain},{nullptr,nullptr}};
    if(!StartServiceCtrlDispatcherW(table)){const DWORD e=GetLastError();if(e==ERROR_FAILED_SERVICE_CONTROLLER_CONNECT)std::fwprintf(stderr,L"Use 'status', 'init', 'enable', 'disable', 'reset-password', or --console.\n");return static_cast<int>(e);}return 0;
}
