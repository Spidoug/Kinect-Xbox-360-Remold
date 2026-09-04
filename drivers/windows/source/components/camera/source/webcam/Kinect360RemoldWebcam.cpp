#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfvirtualcamera.h>
#include <setupapi.h>
#include <cstdio>
#include <cwctype>
#include <string>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mfsensorgroup.lib")
#pragma comment(lib, "setupapi.lib")

namespace {
constexpr wchar_t kClsidString[] = L"{D0C8E936-5A2B-4C0D-936F-281501A73691}";
constexpr wchar_t kFriendlyName[] = L"Kinect Xbox 360 Camera";
const GUID kVcamKind = {0xc7f7c57b,0xdf30,0x41d0,{0xaf,0xfc,0x15,0x20,0x1c,0xdf,0x92,0x0d}};

void PrintHr(const wchar_t* what, HRESULT hr) {
    std::fwprintf(stderr, L"%ls failed: 0x%08X\n", what, static_cast<unsigned>(hr));
}

HRESULT SetRegString(HKEY root, const std::wstring& subkey, const wchar_t* name, const std::wstring& value) {
    HKEY key = nullptr;
    LONG rc = RegCreateKeyExW(root, subkey.c_str(), 0, nullptr, 0,
                              KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, &key, nullptr);
    if (rc != ERROR_SUCCESS) return HRESULT_FROM_WIN32(rc);
    const BYTE* bytes = reinterpret_cast<const BYTE*>(value.c_str());
    const DWORD cb = static_cast<DWORD>((value.size()+1) * sizeof(wchar_t));
    rc = RegSetValueExW(key, name, 0, REG_SZ, bytes, cb);
    RegCloseKey(key);
    return HRESULT_FROM_WIN32(rc);
}

HRESULT RegisterComServer(const std::wstring& dllPath) {
    const std::wstring base = std::wstring(L"SOFTWARE\\Classes\\CLSID\\") + kClsidString;
    HRESULT hr = SetRegString(HKEY_LOCAL_MACHINE, base, nullptr, L"Kinect Xbox 360 Camera Source");
    if (FAILED(hr)) return hr;
    hr = SetRegString(HKEY_LOCAL_MACHINE, base + L"\\InprocServer32", nullptr, dllPath);
    if (FAILED(hr)) {
        (void)RegDeleteTreeW(HKEY_LOCAL_MACHINE, base.c_str());
        return hr;
    }
    hr = SetRegString(HKEY_LOCAL_MACHINE, base + L"\\InprocServer32", L"ThreadingModel", L"Both");
    if (FAILED(hr)) (void)RegDeleteTreeW(HKEY_LOCAL_MACHINE, base.c_str());
    return hr;
}

HRESULT UnregisterComServer() {
    const std::wstring base = std::wstring(L"SOFTWARE\\Classes\\CLSID\\") + kClsidString;
    LONG rc = RegDeleteTreeW(HKEY_LOCAL_MACHINE, base.c_str());
    if (rc == ERROR_FILE_NOT_FOUND) return S_OK;
    return HRESULT_FROM_WIN32(rc);
}


HRESULT FindPnPCamera(std::wstring& instanceId) {
    instanceId.clear();
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());

    HRESULT result = S_FALSE;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{};
        data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) {
            const DWORD error = GetLastError();
            if (error != ERROR_NO_MORE_ITEMS && result == S_FALSE) result = HRESULT_FROM_WIN32(error);
            break;
        }

        wchar_t name[512]{};
        DWORD type = 0;
        DWORD bytes = 0;
        bool haveName = SetupDiGetDeviceRegistryPropertyW(
            set, &data, SPDRP_FRIENDLYNAME, &type,
            reinterpret_cast<PBYTE>(name), sizeof(name), &bytes) != FALSE;
        if (!haveName) {
            haveName = SetupDiGetDeviceRegistryPropertyW(
                set, &data, SPDRP_DEVICEDESC, &type,
                reinterpret_cast<PBYTE>(name), sizeof(name), &bytes) != FALSE;
        }
        if (!haveName || _wcsicmp(name, kFriendlyName) != 0) continue;

        wchar_t id[1024]{};
        if (!SetupDiGetDeviceInstanceIdW(set, &data, id, ARRAYSIZE(id), nullptr)) continue;
        std::wstring upper = id;
        for (auto& ch : upper) ch = static_cast<wchar_t>(towupper(ch));
        if (upper.rfind(L"SWD\\VCAMDEVAPI\\", 0) != 0) continue;
        instanceId = id;
        result = S_OK;
        break;
    }
    SetupDiDestroyDeviceInfoList(set);
    return result;
}

HRESULT FindEnumeratedCamera(std::wstring& symbolicLink) {
    symbolicLink.clear();
    IMFAttributes* attributes = nullptr;
    HRESULT hr = MFCreateAttributes(&attributes, 1);
    if (FAILED(hr)) return hr;

    hr = attributes->SetGUID(
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    if (FAILED(hr)) {
        attributes->Release();
        return hr;
    }

    IMFActivate** devices = nullptr;
    UINT32 count = 0;
    hr = MFEnumDeviceSources(attributes, &devices, &count);
    attributes->Release();
    if (FAILED(hr)) return hr;

    bool found = false;
    for (UINT32 index = 0; index < count; ++index) {
        IMFActivate* activate = devices[index];
        if (!activate) continue;

        LPWSTR friendly = nullptr;
        UINT32 friendlyChars = 0;
        const HRESULT nameHr = activate->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &friendly, &friendlyChars);
        const bool match = SUCCEEDED(nameHr) && friendly && _wcsicmp(friendly, kFriendlyName) == 0;
        if (friendly) CoTaskMemFree(friendly);

        if (match) {
            LPWSTR link = nullptr;
            UINT32 linkChars = 0;
            const HRESULT linkHr = activate->GetAllocatedString(
                MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                &link,
                &linkChars);
            if (SUCCEEDED(linkHr) && link) symbolicLink.assign(link, linkChars);
            if (link) CoTaskMemFree(link);
            found = true;
        }
    }

    for (UINT32 index = 0; index < count; ++index) {
        if (devices[index]) devices[index]->Release();
    }
    CoTaskMemFree(devices);
    return found ? S_OK : S_FALSE;
}

HRESULT OpenVirtualCamera(IMFVirtualCamera** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    return MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System,
        MFVirtualCameraAccess_AllUsers,
        kFriendlyName,
        kClsidString,
        nullptr,
        0,
        out);
}

// MFCreateVirtualCamera can return a configuration object even when no
// underlying system-lifetime camera is currently registered. Start() populates
// this symbolic-link attribute. Checking it prevents calling Remove() on an
// unstarted configuration object, which Media Foundation rejects with
// MF_E_INVALIDREQUEST (0xC00D36B2).
HRESULT GetRegisteredLink(IMFVirtualCamera* camera, std::wstring& link) {
    link.clear();
    if (!camera) return E_POINTER;
    LPWSTR raw = nullptr;
    UINT32 chars = 0;
    const HRESULT hr = camera->GetAllocatedString(
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &raw, &chars);
    if (hr == MF_E_ATTRIBUTENOTFOUND) return S_FALSE;
    if (FAILED(hr)) return hr;
    if (raw) {
        link.assign(raw, chars);
        CoTaskMemFree(raw);
    }
    return S_OK;
}

HRESULT Install(const std::wstring& dllPath) {
    DWORD attrs = GetFileAttributesW(dllPath.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY))
        return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);

    HRESULT hr = RegisterComServer(dllPath);
    if (FAILED(hr)) return hr;

    IMFVirtualCamera* camera = nullptr;
    hr = OpenVirtualCamera(&camera);
    if (FAILED(hr)) {
        (void)UnregisterComServer();
        return hr;
    }

    std::wstring existingLink;
    const HRESULT stateHr = GetRegisteredLink(camera, existingLink);
    if (stateHr == S_OK) {
        // Re-opening an already-started virtual camera is a valid success path.
        // The COM registration above still updates the media-source path for
        // future activations without forcing a state transition on a live camera.
        std::wprintf(L"Virtual camera already registered: %ls\n", existingLink.c_str());
        hr = S_OK;
    } else if (stateHr == S_FALSE) {
        hr = camera->SetUINT32(kVcamKind, 0); // VirtualCameraKind::Synthetic.
        if (SUCCEEDED(hr)) hr = camera->Start(nullptr);
        if (SUCCEEDED(hr)) {
            std::wstring link;
            if (GetRegisteredLink(camera, link) == S_OK && !link.empty())
                std::wprintf(L"Virtual camera registered: %ls\n", link.c_str());
        }
    } else {
        hr = stateHr;
    }

    camera->Shutdown();
    camera->Release();
    if (FAILED(hr)) (void)UnregisterComServer();
    return hr;
}

HRESULT Remove() {
    IMFVirtualCamera* camera = nullptr;
    HRESULT hr = OpenVirtualCamera(&camera);
    if (FAILED(hr)) return hr;

    std::wstring link;
    const HRESULT stateHr = GetRegisteredLink(camera, link);
    if (stateHr == S_FALSE) {
        // No registered virtual camera exists. This is idempotent cleanup, not
        // an error. In particular, do not call Remove() on this configuration
        // object because Media Foundation reports MF_E_INVALIDREQUEST.
        hr = S_OK;
    } else if (FAILED(stateHr)) {
        hr = stateHr;
    } else {
        hr = camera->Remove();
        if (hr == MF_E_INVALIDREQUEST) {
            // A concurrent teardown can invalidate the state between the
            // attribute query and Remove(). Re-check before deciding it failed.
            std::wstring after;
            if (GetRegisteredLink(camera, after) == S_FALSE) hr = S_OK;
        }
    }

    camera->Shutdown();
    camera->Release();
    if (FAILED(hr)) return hr;
    return UnregisterComServer();
}

HRESULT Status() {
    // Media Foundation enumeration can lag behind a valid IMFVirtualCamera
    // registration (for example while Frame Server keeps the device alive).
    // Treat either successful enumeration or an existing registered symbolic
    // link as READY; only report missing when both checks fail.
    std::wstring link;
    const HRESULT enumHr = FindEnumeratedCamera(link);
    if (enumHr == S_OK) {
        if (!link.empty()) std::wprintf(L"OK camera=%ls symbolic-link=%ls\n", kFriendlyName, link.c_str());
        else std::wprintf(L"OK camera=%ls\n", kFriendlyName);
        return S_OK;
    }

    std::wstring pnpInstance;
    const HRESULT pnpHr = FindPnPCamera(pnpInstance);
    if (pnpHr == S_OK) {
        std::wprintf(L"OK camera=%ls pnp-instance=%ls media-foundation-enumeration=deferred\n",
                     kFriendlyName, pnpInstance.c_str());
        return S_OK;
    }

    IMFVirtualCamera* camera = nullptr;
    const HRESULT openHr = OpenVirtualCamera(&camera);
    if (SUCCEEDED(openHr) && camera) {
        std::wstring registeredLink;
        const HRESULT registeredHr = GetRegisteredLink(camera, registeredLink);
        camera->Release();
        if (registeredHr == S_OK && !registeredLink.empty()) {
            std::wprintf(L"OK camera=%ls registered-link=%ls enumeration=deferred\n",
                         kFriendlyName, registeredLink.c_str());
            return S_OK;
        }
    }

    if (enumHr == S_FALSE) {
        std::wprintf(L"NOT_REGISTERED camera=%ls\n", kFriendlyName);
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }
    return enumHr;
}

std::wstring FullPath(const wchar_t* path) {
    DWORD needed = GetFullPathNameW(path, 0, nullptr, nullptr);
    if (!needed) return path ? path : L"";
    std::vector<wchar_t> buf(needed + 1);
    DWORD got = GetFullPathNameW(path, static_cast<DWORD>(buf.size()), buf.data(), nullptr);
    return got ? std::wstring(buf.data(), got) : std::wstring(path);
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) {
        std::fwprintf(stderr, L"Usage:\n  Kinect360RemoldWebcam install <media-source-dll>\n  Kinect360RemoldWebcam remove\n  Kinect360RemoldWebcam status\n");
        return 2;
    }
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninit = SUCCEEDED(hr);
    if (hr == RPC_E_CHANGED_MODE) hr = S_OK;
    if (FAILED(hr)) { PrintHr(L"CoInitializeEx", hr); return 3; }
    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(hr)) { PrintHr(L"MFStartup", hr); if (uninit) CoUninitialize(); return 4; }

    if (_wcsicmp(argv[1], L"install") == 0) {
        if (argc != 3) hr = E_INVALIDARG;
        else hr = Install(FullPath(argv[2]));
    } else if (_wcsicmp(argv[1], L"remove") == 0) {
        hr = Remove();
    } else if (_wcsicmp(argv[1], L"status") == 0 && argc == 2) {
        hr = Status();
    } else {
        hr = E_INVALIDARG;
    }

    MFShutdown();
    if (uninit) CoUninitialize();
    if (FAILED(hr)) {
        PrintHr(L"Kinect360RemoldWebcam", hr);
        if (hr == E_ACCESSDENIED) std::fwprintf(stderr, L"Run this command elevated as Administrator.\n");
        return 1;
    }
    std::wprintf(L"PASS\n");
    return 0;
}
