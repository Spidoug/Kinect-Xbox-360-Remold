#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <cfgmgr32.h>
#include <cstdio>
#include <cwchar>
#include <cwctype>
#include <string>
#include <vector>
#include <algorithm>
#include <set>

#include "Kinect360RemoldHardwareProfile.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "newdev.lib")
#pragma comment(lib, "cfgmgr32.lib")

namespace {
std::wstring FullPath(const wchar_t* path) {
    if (!path) return L"";
    DWORD needed = GetFullPathNameW(path, 0, nullptr, nullptr);
    if (!needed) return path;
    std::vector<wchar_t> buf(needed + 1);
    DWORD got = GetFullPathNameW(path, static_cast<DWORD>(buf.size()), buf.data(), nullptr);
    return got ? std::wstring(buf.data(), got) : std::wstring(path);
}

void PrintWin32(const wchar_t* what, DWORD err) {
    wchar_t* msg = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, err, 0, reinterpret_cast<LPWSTR>(&msg), 0, nullptr);
    std::fwprintf(stderr, L"%ls failed: %lu (0x%08lX)%ls%ls\n", what, err, err,
                  msg ? L" - " : L"", msg ? msg : L"");
    if (msg) LocalFree(msg);
}

bool FileExists(const std::wstring& path) {
    DWORD a = GetFileAttributesW(path.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

bool DeviceMatchesHardwareId(HDEVINFO set, SP_DEVINFO_DATA* data, const std::wstring& hardwareId);
bool ContainsInsensitive(const std::wstring& text, const std::wstring& needle);

std::wstring CanonicalPhysicalHardwareId(uint16_t productId) {
    wchar_t id[32]{};
    _snwprintf_s(id, _countof(id), _TRUNCATE, L"USB\\VID_%04X&PID_%04X",
                 static_cast<unsigned>(Kinect360RemoldHardware::kVendorId),
                 static_cast<unsigned>(productId));
    return id;
}

bool IsTargetKinectFunction(const std::wstring& upperId, std::wstring* canonical) {
    const uint16_t productIds[] = {
        Kinect360RemoldHardware::kAudioProductId,
        Kinect360RemoldHardware::kCameraProductId,
        Kinect360RemoldHardware::kMotorProductId,
    };
    for (const uint16_t productId : productIds) {
        const std::wstring target = CanonicalPhysicalHardwareId(productId);
        if (upperId.rfind(target, 0) == 0) {
            if (canonical) *canonical = target;
            return true;
        }
    }
    return false;
}

DWORD FindPresentHardwareId(const std::wstring& hardwareId, bool* found) {
    if (!found) return ERROR_INVALID_PARAMETER;
    *found = false;
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return GetLastError();

    DWORD result = ERROR_SUCCESS;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{};
        data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) {
            const DWORD e = GetLastError();
            if (e != ERROR_NO_MORE_ITEMS) result = e;
            break;
        }
        if (DeviceMatchesHardwareId(set, &data, hardwareId)) {
            *found = true;
            break;
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return result;
}

DWORD BindHardwareId(const std::wstring& hardwareId, const std::wstring& infPath, bool* reboot) {
    if (!FileExists(infPath)) return ERROR_FILE_NOT_FOUND;

    bool present = false;
    DWORD e = FindPresentHardwareId(hardwareId, &present);
    if (e != ERROR_SUCCESS) return e;
    if (!present) return ERROR_NO_SUCH_DEVINST;

    // Install.ps1 validates the package signature, trusts the packaged
    // development certificate, and pre-stages all five INFs before any device
    // mutation. Binding therefore does not perform Driver Store trust work mid-bind
    // and cannot fall back to a NULL driver because staging failed mid-operation.
    BOOL needsReboot = FALSE;
    SetLastError(ERROR_SUCCESS);
    const BOOL installed = UpdateDriverForPlugAndPlayDevicesW(
        nullptr,
        hardwareId.c_str(),
        infPath.c_str(),
        INSTALLFLAG_FORCE,
        &needsReboot);
    e = installed ? ERROR_SUCCESS : GetLastError();

    if (!installed) {
        if (e == ERROR_SUCCESS) e = ERROR_GEN_FAILURE;
        std::fwprintf(stderr,
            L"UpdateDriverForPlugAndPlayDevicesW could not bind the pre-staged package for hardware-id=%ls from INF=%ls. "
            L"See %%WINDIR%%\\INF\\setupapi.dev.log for the authoritative PnP reason.\n",
            hardwareId.c_str(), infPath.c_str());
        return e;
    }
    if (reboot) *reboot = needsReboot != FALSE;
    std::wprintf(L"INSTALLED hardware-id=%ls method=UpdateDriverForPlugAndPlayDevicesW prestaged=1\n",
                 hardwareId.c_str());
    return ERROR_SUCCESS;
}

DWORD BindCompatibleDriverByProvider(const std::wstring& hardwareId,
                                     const std::wstring& providerSubstring,
                                     const std::wstring& descriptionSubstring,
                                     bool* reboot) {
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return GetLastError();

    DWORD firstError = ERROR_SUCCESS;
    unsigned matchedDevices = 0;
    unsigned boundDevices = 0;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{};
        data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) {
            const DWORD e = GetLastError();
            if (e != ERROR_NO_MORE_ITEMS && firstError == ERROR_SUCCESS) firstError = e;
            break;
        }
        if (!DeviceMatchesHardwareId(set, &data, hardwareId)) continue;
        ++matchedDevices;

        SP_DEVINSTALL_PARAMS_W installParams{};
        installParams.cbSize = sizeof(installParams);
        if (!SetupDiGetDeviceInstallParamsW(set, &data, &installParams)) {
            if (firstError == ERROR_SUCCESS) firstError = GetLastError();
            continue;
        }
        installParams.FlagsEx |= DI_FLAGSEX_ALLOWEXCLUDEDDRVS;
        if (!SetupDiSetDeviceInstallParamsW(set, &data, &installParams)) {
            if (firstError == ERROR_SUCCESS) firstError = GetLastError();
            continue;
        }
        if (!SetupDiBuildDriverInfoList(set, &data, SPDIT_COMPATDRIVER)) {
            if (firstError == ERROR_SUCCESS) firstError = GetLastError();
            continue;
        }

        bool found = false;
        SP_DRVINFO_DATA_W selected{};
        for (DWORD driverIndex = 0;; ++driverIndex) {
            SP_DRVINFO_DATA_W candidate{};
            candidate.cbSize = sizeof(candidate);
            if (!SetupDiEnumDriverInfoW(set, &data, SPDIT_COMPATDRIVER, driverIndex, &candidate)) {
                const DWORD e = GetLastError();
                if (e != ERROR_NO_MORE_ITEMS && firstError == ERROR_SUCCESS) firstError = e;
                break;
            }
            const std::wstring provider = candidate.ProviderName;
            const std::wstring description = candidate.Description;
            if (!ContainsInsensitive(provider, providerSubstring) ||
                !ContainsInsensitive(description, descriptionSubstring)) continue;
            selected = candidate;
            found = true;
            break;
        }

        if (!found) {
            SetupDiDestroyDriverInfoList(set, &data, SPDIT_COMPATDRIVER);
            if (firstError == ERROR_SUCCESS) firstError = ERROR_NOT_FOUND;
            continue;
        }

        if (!SetupDiSetSelectedDriverW(set, &data, &selected)) {
            const DWORD e = GetLastError();
            SetupDiDestroyDriverInfoList(set, &data, SPDIT_COMPATDRIVER);
            if (firstError == ERROR_SUCCESS) firstError = e;
            continue;
        }
        BOOL needsReboot = FALSE;
        if (!DiInstallDevice(nullptr, set, &data, &selected, 0, &needsReboot)) {
            const DWORD e = GetLastError();
            SetupDiDestroyDriverInfoList(set, &data, SPDIT_COMPATDRIVER);
            if (firstError == ERROR_SUCCESS) firstError = e;
            continue;
        }
        if (reboot && needsReboot) *reboot = true;
        ++boundDevices;
        std::wprintf(L"BOUND hardware-id=%ls provider=%ls description=%ls\n",
                     hardwareId.c_str(), selected.ProviderName, selected.Description);
        SetupDiDestroyDriverInfoList(set, &data, SPDIT_COMPATDRIVER);
    }

    SetupDiDestroyDeviceInfoList(set);
    if (matchedDevices == 0) return ERROR_NO_SUCH_DEVINST;
    if (boundDevices != 0) return ERROR_SUCCESS;
    return firstError != ERROR_SUCCESS ? firstError : ERROR_NOT_FOUND;
}

std::vector<std::wstring> DeviceHardwareIds(HDEVINFO set, SP_DEVINFO_DATA* data) {
    DWORD type = 0, bytes = 0;
    SetupDiGetDeviceRegistryPropertyW(set, data, SPDRP_HARDWAREID, &type, nullptr, 0, &bytes);
    DWORD err = GetLastError();
    if (!bytes || (err != ERROR_INSUFFICIENT_BUFFER && err != ERROR_SUCCESS)) return {};
    std::vector<BYTE> buf(bytes + sizeof(wchar_t) * 2, 0);
    if (!SetupDiGetDeviceRegistryPropertyW(set, data, SPDRP_HARDWAREID, &type, buf.data(), bytes, &bytes)) return {};
    std::vector<std::wstring> ids;
    const wchar_t* p = reinterpret_cast<const wchar_t*>(buf.data());
    const wchar_t* end = reinterpret_cast<const wchar_t*>(buf.data() + buf.size());
    while (p < end && *p) {
        ids.emplace_back(p);
        p += wcslen(p) + 1;
    }
    return ids;
}

bool DeviceMatchesHardwareId(HDEVINFO set, SP_DEVINFO_DATA* data, const std::wstring& hardwareId) {
    const auto ids = DeviceHardwareIds(set, data);
    for (const auto& id : ids) if (_wcsicmp(id.c_str(), hardwareId.c_str()) == 0) return true;
    return false;
}

std::wstring DeviceRegistryString(HDEVINFO set, SP_DEVINFO_DATA* data, DWORD property) {
    DWORD type = 0, bytes = 0;
    SetupDiGetDeviceRegistryPropertyW(set, data, property, &type, nullptr, 0, &bytes);
    const DWORD e = GetLastError();
    if (!bytes || (e != ERROR_INSUFFICIENT_BUFFER && e != ERROR_SUCCESS)) return L"";
    std::vector<BYTE> buffer(bytes + sizeof(wchar_t), 0);
    if (!SetupDiGetDeviceRegistryPropertyW(set, data, property, &type, buffer.data(), bytes, &bytes)) return L"";
    if (type != REG_SZ && type != REG_EXPAND_SZ) return L"";
    return std::wstring(reinterpret_cast<const wchar_t*>(buffer.data()));
}

bool ContainsInsensitive(const std::wstring& text, const std::wstring& needle) {
    if (needle.empty()) return true;
    std::wstring a = text;
    std::wstring b = needle;
    std::transform(a.begin(), a.end(), a.begin(), [](wchar_t ch){ return static_cast<wchar_t>(std::towupper(ch)); });
    std::transform(b.begin(), b.end(), b.begin(), [](wchar_t ch){ return static_cast<wchar_t>(std::towupper(ch)); });
    return a.find(b) != std::wstring::npos;
}

DWORD ProbePresentKinectFunctions() {
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return GetLastError();
    std::set<std::wstring> normalized;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{}; data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) {
            DWORD e = GetLastError();
            if (e != ERROR_NO_MORE_ITEMS) { SetupDiDestroyDeviceInfoList(set); return e; }
            break;
        }
        for (const auto& id : DeviceHardwareIds(set, &data)) {
            std::wstring upper = id;
            std::transform(upper.begin(), upper.end(), upper.begin(), [](wchar_t ch){ return static_cast<wchar_t>(std::towupper(ch)); });
            std::wstring canonical;
            // The supported function set comes from the shared physical profile;
            // Setup must not maintain a second VID/PID table that can drift.
            if (IsTargetKinectFunction(upper, &canonical)) normalized.insert(canonical);
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    if (normalized.empty()) {
        std::wprintf(L"PRESENT NONE\n");
    } else {
        for (const auto& id : normalized) std::wprintf(L"PRESENT %ls\n", id.c_str());
    }
    return ERROR_SUCCESS;
}

DWORD ProbeDeviceStatus(const std::wstring& hardwareId) {
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return GetLastError();

    bool found = false;
    bool ready = false;
    DWORD firstError = ERROR_SUCCESS;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{};
        data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) {
            const DWORD e = GetLastError();
            if (e != ERROR_NO_MORE_ITEMS && firstError == ERROR_SUCCESS) firstError = e;
            break;
        }
        if (!DeviceMatchesHardwareId(set, &data, hardwareId)) continue;
        found = true;

        ULONG devnodeStatus = 0;
        ULONG problem = 0;
        const CONFIGRET cr = CM_Get_DevNode_Status(&devnodeStatus, &problem, data.DevInst, 0);
        if (cr != CR_SUCCESS && firstError == ERROR_SUCCESS) firstError = ERROR_GEN_FAILURE;

        wchar_t instanceId[MAX_DEVICE_ID_LEN]{};
        if (CM_Get_Device_IDW(data.DevInst, instanceId, MAX_DEVICE_ID_LEN, 0) != CR_SUCCESS) {
            instanceId[0] = L'\0';
        }
        const std::wstring service = DeviceRegistryString(set, &data, SPDRP_SERVICE);
        std::wstring name = DeviceRegistryString(set, &data, SPDRP_FRIENDLYNAME);
        if (name.empty()) name = DeviceRegistryString(set, &data, SPDRP_DEVICEDESC);

        const bool started = cr == CR_SUCCESS && (devnodeStatus & DN_STARTED) != 0 && problem == 0;
        if (started) ready = true;
        std::wprintf(L"%ls hardware-id=%ls instance=%ls service=%ls name=%ls started=%u problem=%lu status=0x%08lX\n",
                     started ? L"READY" : L"NOT_READY",
                     hardwareId.c_str(),
                     instanceId[0] ? instanceId : L"(unknown)",
                     service.empty() ? L"(none)" : service.c_str(),
                     name.empty() ? L"(unknown)" : name.c_str(),
                     started ? 1u : 0u,
                     problem,
                     devnodeStatus);
    }
    SetupDiDestroyDeviceInfoList(set);

    if (ready) return ERROR_SUCCESS;
    if (found) return ERROR_NOT_READY;
    if (firstError != ERROR_SUCCESS) return firstError;
    std::wprintf(L"NOT_PRESENT hardware-id=%ls\n", hardwareId.c_str());
    return ERROR_NO_SUCH_DEVINST;
}

DWORD RemoveDevicesByHardwareId(const std::wstring& hardwareId, unsigned* removed) {
    if (removed) *removed = 0;
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES);
    if (set == INVALID_HANDLE_VALUE) return GetLastError();
    DWORD firstError = ERROR_SUCCESS;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{}; data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) {
            DWORD e = GetLastError();
            if (e != ERROR_NO_MORE_ITEMS && firstError == ERROR_SUCCESS) firstError = e;
            break;
        }
        if (!DeviceMatchesHardwareId(set, &data, hardwareId)) continue;
        SP_REMOVEDEVICE_PARAMS params{};
        params.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        params.ClassInstallHeader.InstallFunction = DIF_REMOVE;
        params.Scope = DI_REMOVEDEVICE_GLOBAL;
        params.HwProfile = 0;
        if (!SetupDiSetClassInstallParamsW(set, &data, &params.ClassInstallHeader, sizeof(params)) ||
            !SetupDiCallClassInstaller(DIF_REMOVE, set, &data)) {
            DWORD e = GetLastError();
            if (firstError == ERROR_SUCCESS) firstError = e;
        } else if (removed) {
            ++*removed;
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return firstError;
}

DWORD ChangeDeviceStateByHardwareId(const std::wstring& hardwareId, DWORD stateChange, unsigned* changed) {
    if (changed) *changed = 0;
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return GetLastError();

    DWORD firstError = ERROR_SUCCESS;
    unsigned matches = 0;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{};
        data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) {
            const DWORD e = GetLastError();
            if (e != ERROR_NO_MORE_ITEMS && firstError == ERROR_SUCCESS) firstError = e;
            break;
        }
        if (!DeviceMatchesHardwareId(set, &data, hardwareId)) continue;
        ++matches;

        SP_PROPCHANGE_PARAMS params{};
        params.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        params.ClassInstallHeader.InstallFunction = DIF_PROPERTYCHANGE;
        params.StateChange = stateChange;
        params.Scope = DICS_FLAG_GLOBAL;
        params.HwProfile = 0;

        if (!SetupDiSetClassInstallParamsW(
                set, &data, &params.ClassInstallHeader, sizeof(params)) ||
            !SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, set, &data)) {
            const DWORD e = GetLastError();
            // A device can legitimately disappear between enumeration and the
            // property-change request while PnP rebuilds the USB tree. Treat that
            // specific race as transient; a fresh pass below decides presence.
            if (e == ERROR_NO_SUCH_DEVINST || e == ERROR_NOT_FOUND) continue;
            if (firstError == ERROR_SUCCESS) firstError = e;
            continue;
        }
        if (changed) ++*changed;
    }

    SetupDiDestroyDeviceInfoList(set);
    if (matches == 0 && firstError == ERROR_SUCCESS) return ERROR_NO_SUCH_DEVINST;
    return firstError;
}

DWORD RestartDevicesByHardwareId(const std::wstring& hardwareId, unsigned* restarted) {
    if (restarted) *restarted = 0;

    // Prefer a property-change restart: it asks PnP to stop and rebuild the
    // device stack without requiring a full Windows reboot.
    unsigned changed = 0;
    DWORD e = ChangeDeviceStateByHardwareId(hardwareId, DICS_PROPCHANGE, &changed);
    if (e == ERROR_SUCCESS && changed > 0) {
        if (restarted) *restarted = changed;
        return ERROR_SUCCESS;
    }

    // Some class installers do not implement DICS_PROPCHANGE. Fall back to
    // a controlled disable/enable cycle, still scoped only to this Kinect
    // hardware ID.
    unsigned disabled = 0;
    const DWORD disableError = ChangeDeviceStateByHardwareId(hardwareId, DICS_DISABLE, &disabled);
    if (disableError != ERROR_SUCCESS || disabled == 0)
        return disableError != ERROR_SUCCESS ? disableError : (e != ERROR_SUCCESS ? e : ERROR_GEN_FAILURE);

    Sleep(200);

    unsigned enabled = 0;
    const DWORD enableError = ChangeDeviceStateByHardwareId(hardwareId, DICS_ENABLE, &enabled);
    if (enableError != ERROR_SUCCESS) return enableError;
    if (enabled == 0) return ERROR_GEN_FAILURE;

    if (restarted) *restarted = enabled;
    return ERROR_SUCCESS;
}

DWORD CreateRootDevice(const std::wstring& hardwareId, const std::wstring& infPath, const std::wstring& friendlyName) {
    (void)friendlyName;
    GUID classGuid{};
    wchar_t className[MAX_CLASS_NAME_LEN]{};
    DWORD required = 0;
    if (!SetupDiGetINFClassW(infPath.c_str(), &classGuid, className, MAX_CLASS_NAME_LEN, &required))
        return GetLastError();
    HDEVINFO set = SetupDiCreateDeviceInfoList(&classGuid, nullptr);
    if (set == INVALID_HANDLE_VALUE) return GetLastError();
    SP_DEVINFO_DATA data{}; data.cbSize = sizeof(data);
    // Mirror the official DevCon install path: with DICD_GENERATE_ID, use the INF class name
    // for the temporary device-information element; the actual match is established by SPDRP_HARDWAREID.
    if (!SetupDiCreateDeviceInfoW(set, className, &classGuid, nullptr, nullptr,
                                  DICD_GENERATE_ID, &data)) {
        DWORD e = GetLastError(); SetupDiDestroyDeviceInfoList(set); return e;
    }
    std::vector<wchar_t> ids(hardwareId.size() + 2, L'\0');
    std::copy(hardwareId.begin(), hardwareId.end(), ids.begin());
    const DWORD bytes = static_cast<DWORD>(ids.size() * sizeof(wchar_t));
    if (!SetupDiSetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID,
                                           reinterpret_cast<const BYTE*>(ids.data()), bytes)) {
        DWORD e = GetLastError(); SetupDiDestroyDeviceInfoList(set); return e;
    }
    if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &data)) {
        DWORD e = GetLastError(); SetupDiDestroyDeviceInfoList(set); return e;
    }
    SetupDiDestroyDeviceInfoList(set);
    return ERROR_SUCCESS;
}

DWORD EnsureRoot(const std::wstring& hardwareId, const std::wstring& infPath, const std::wstring& friendlyName, bool* reboot) {
    // Do not probe a not-yet-created root device by asking an install API to
    // update it.  First determine whether the devnode exists, create it when it
    // does not, and only then bind the package that Install.ps1 already verified and staged.
    // This mirrors DevCon's create/register-then-install ordering without
    // performing Driver Store staging in the middle of devnode creation.
    bool present = false;
    DWORD e = FindPresentHardwareId(hardwareId, &present);
    if (e != ERROR_SUCCESS) return e;

    bool created = false;
    if (!present) {
        e = CreateRootDevice(hardwareId, infPath, friendlyName);
        if (e != ERROR_SUCCESS) return e;
        created = true;
    }

    e = BindHardwareId(hardwareId, infPath, reboot);
    if (e != ERROR_SUCCESS && created) {
        unsigned removed = 0;
        (void)RemoveDevicesByHardwareId(hardwareId, &removed);
    }
    return e;
}


void Usage() {
    std::fwprintf(stderr,
        L"Usage:\n"
        L"  Kinect360RemoldSetup probe\n"
        L"  Kinect360RemoldSetup device-status <hardware-id>\n"
        L"  Kinect360RemoldSetup bind <hardware-id> <inf>\n"
        L"  Kinect360RemoldSetup bind-provider <hardware-id> <provider-substring> <description-substring>\n"
        L"  Kinect360RemoldSetup ensure-root <hardware-id> <inf> <friendly-name>\n"
        L"  Kinect360RemoldSetup remove <hardware-id>\n"
        L"  Kinect360RemoldSetup restart <hardware-id>\n");
}
}

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) { Usage(); return 2; }
    const std::wstring cmd = argv[1];
    if (_wcsicmp(cmd.c_str(), L"probe") == 0) {
        if (argc != 2) { Usage(); return 2; }
        DWORD pe = ProbePresentKinectFunctions();
        if (pe != ERROR_SUCCESS) { PrintWin32(L"Kinect360RemoldSetup probe", pe); return 1; }
        return 0;
    }
    if (_wcsicmp(cmd.c_str(), L"device-status") == 0) {
        if (argc != 3) { Usage(); return 2; }
        const DWORD ds = ProbeDeviceStatus(argv[2]);
        return ds == ERROR_SUCCESS ? 0 : (ds == ERROR_NO_SUCH_DEVINST ? 3 : (ds == ERROR_NOT_READY ? 4 : 1));
    }
    if (argc < 3) { Usage(); return 2; }
    const std::wstring hardwareId = argv[2];
    DWORD e = ERROR_INVALID_PARAMETER;
    bool reboot = false;
    if (_wcsicmp(cmd.c_str(), L"bind") == 0) {
        if (argc != 4) { Usage(); return 2; }
        e = BindHardwareId(hardwareId, FullPath(argv[3]), &reboot);
    } else if (_wcsicmp(cmd.c_str(), L"bind-provider") == 0) {
        if (argc != 5) { Usage(); return 2; }
        e = BindCompatibleDriverByProvider(hardwareId, argv[3], argv[4], &reboot);
    } else if (_wcsicmp(cmd.c_str(), L"ensure-root") == 0) {
        if (argc != 5) { Usage(); return 2; }
        e = EnsureRoot(hardwareId, FullPath(argv[3]), argv[4], &reboot);
    } else if (_wcsicmp(cmd.c_str(), L"remove") == 0) {
        if (argc != 3) { Usage(); return 2; }
        unsigned removed = 0;
        e = RemoveDevicesByHardwareId(hardwareId, &removed);
        if (e == ERROR_SUCCESS) std::wprintf(L"Removed %u matching device(s).\n", removed);
    } else if (_wcsicmp(cmd.c_str(), L"restart") == 0) {
        if (argc != 3) { Usage(); return 2; }
        unsigned restarted = 0;
        e = RestartDevicesByHardwareId(hardwareId, &restarted);
        if (e == ERROR_NO_SUCH_DEVINST) {
            // Idempotent hot reload: disappearance during USB/PnP reenumeration is
            // not an installer failure. The caller performs a fresh probe/rebind.
            std::wprintf(L"NOT_PRESENT hardware-id=%ls\n", hardwareId.c_str());
            return 0;
        }
        if (e == ERROR_SUCCESS) std::wprintf(L"Hot-restarted %u matching device(s).\n", restarted);
    } else {
        Usage(); return 2;
    }
    if (e != ERROR_SUCCESS) {
        PrintWin32(L"Kinect360RemoldSetup", e);
        if (e == ERROR_NO_SUCH_DEVINST) {
            std::fwprintf(stderr, L"No present device has the requested hardware ID: %ls\n", hardwareId.c_str());
            std::fwprintf(stderr, L"This is a PnP enumeration / hardware-family mismatch, not a Driver Store staging error.\n");
        }
        return 1;
    }
    if (reboot) std::wprintf(L"Driver update requested a PnP stack refresh; the installer performs hot-reload in this boot.\n");
    std::wprintf(L"PASS\n");
    return 0;
}
