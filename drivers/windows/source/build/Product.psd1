@{
    Name        = 'Kinect Xbox 360 Remold'
    Version     = '1.0'
    VersionQuad = '1.0.0.0'
    DriverDate  = '08/29/2026'
    Author      = 'Douglas Santana'
    Handle      = '@spidoug'
    Prefix      = 'Kinect360Remold'

    # All external source identities and integrity pins live here. Component
    # build scripts consume this block instead of carrying private commit/URL
    # exceptions, so updating a dependency is one deliberate product change.
    Dependencies = @{
        WindowsCamera = @{
            Kind = 'GitArchive'
            Repository = 'https://github.com/microsoft/Windows-Camera'
            Commit = '790ac218eba8b6995393e9cc9537dfd7730fdb83'
            ArchiveUrls = @(
                'https://codeload.github.com/microsoft/Windows-Camera/zip/{0}',
                'https://github.com/microsoft/Windows-Camera/archive/{0}.zip'
            )
        }
        KinectUacFirmware = @{
            Kind = 'HttpsArtifact'
            Source = 'Microsoft Kinect for Windows Runtime v1.8'
            RuntimeVersion = '1.8.0.595'
            FirmwareVersion = '01.02.709.00'
            Url = 'https://download.microsoft.com/download/E/C/5/EC50686B-82F4-4DBF-A922-980183B214E6/KinectRuntime-v1.8-Setup.exe'
            Sha256 = 'f4d4143fb0f0a8d276889c077bfc8af42bfe99c128cadab5e316bf015a9858e9'
            BundleFileName = 'KinectRuntime-v1.8-Setup.exe'
            DriverMsiName = 'KinectDrivers-v1.8-x86.WHQL.msi'
            FirmwareFileName = 'UACFirmware'
            WixPortableSource = 'NuGet wix 3.14.1 official binaries'
            WixPortableVersion = '3.14.1'
            WixPortableUrl = 'https://www.nuget.org/api/v2/package/wix/3.14.1'
            WixPortableFileName = 'wix.3.14.1.nupkg'
        }
    }

    MinimumWindowsBuild = 22000
    StartupTiltDegrees = 6
    TiltMinDegrees = -27
    TiltMaxDegrees = 27

    # Local virtual-camera consumption lease used by Smart Tilt.
    VirtualCameraActiveLeaseMs = 2000
    SmartTiltPolicy = @{
        FacePeriodMs = 40
        StatusPeriodMs = 80
        CommandPeriodMs = 90
        FaceVerticalDeadZonePixels = 10
        FaceErrorFilterAlpha = 0.35
        AccelFilterAlpha = 0.30
        AccelCorrectionFilterAlpha = 0.30
        MinCommandDeltaDegrees = 1
        MotorSettleToleranceDegrees = 1
        MotorSettleMs = 140
    }
    # Native IP-camera runtime. It consumes the same RGB shared-memory transport
    # as the Windows virtual camera and never opens the Kinect USB device itself.
    CameraIpPolicy = @{
        Enabled = $true
        Bind = '0.0.0.0'
        Port = 8088
        User = 'admin'
        Fps = 8
        JpegQuality = 78
        MaxClients = 8
        FirewallProfile = 'Private'
        FirewallRemoteIp = 'LocalSubnet'
        FirewallRuleName = 'Kinect Xbox 360 Remold IP Camera'
    }
    # Central native-runtime policy. Dependency project normalizers consume this
    # table by configuration instead of patching repeated XML literals by count.
    UserModeRuntimeLibraryPolicy = @{
        Debug = 'MultiThreadedDebug'
        Release = 'MultiThreaded'
    }
    DriverTargetPlatform = 'Desktop'
    Inf2CatOs = @('10_CO_X64','10_NI_X64','10_GE_X64','10_25H2_X64')
    DevelopmentCertificateSubject = 'CN=Kinect Xbox 360 Remold Development'

    DriverPackages = @(
        @{ Key='Device';  DisplayName='Kinect Xbox 360 Remold device'; Inf='drivers\device\Kinect360RemoldDevice.inf'; Cat='drivers\device\Kinect360RemoldDevice.cat'; RootHardwareId='ROOT\Kinect360RemoldDevice' },
        @{ Key='Motor';   DisplayName='Xbox NUI Motor (1414)'; Inf='drivers\nui\Kinect360RemoldNui.inf';       Cat='drivers\nui\Kinect360RemoldNui.cat'; HardwareId='USB\VID_045E&PID_02B0'; HardwareIds=@('USB\VID_045E&PID_02B0') },
        @{ Key='Camera';  DisplayName='Xbox NUI Camera transport';     Inf='drivers\camera\Kinect360RemoldCamera.inf'; Cat='drivers\camera\Kinect360RemoldCamera.cat'; HardwareId='USB\VID_045E&PID_02AE' },
        @{ Key='Audio';   DisplayName='Xbox NUI Audio transport';      Inf='drivers\audio\Kinect360RemoldAudio.inf';    Cat='drivers\audio\Kinect360RemoldAudio.cat'; HardwareId='USB\VID_045E&PID_02AD' }
        @{ Key='Control1473'; DisplayName='Xbox NUI Audio Array Control (1473/UAC)'; Inf='drivers\control1473\Kinect360Remold1473Control.inf'; Cat='drivers\control1473\Kinect360Remold1473Control.cat'; HardwareId='USB\VID_045E&PID_02BB&MI_00'; HardwareIds=@('USB\VID_045E&PID_02BB&MI_00','USB\VID_045E&PID_02C3&MI_00') }
    )

    Services = @{
        Broker = 'Kinect360RemoldBroker'
        CameraBridge = 'Kinect360RemoldCameraBridge'
        CameraIp = 'Kinect360RemoldCameraIp'
        AudioBridge = 'Kinect360RemoldAudioBridge'
    }
    ServiceOrder = @('Broker','CameraBridge','CameraIp','AudioBridge')
    WindowsCameraName = 'Kinect Xbox 360 Camera'
    AudioPipeName = '\\.\pipe\Kinect360RemoldAudio'
    Kinect1473HubHardwareId = 'USB\VID_045E&PID_02C2'
    # UACFirmware 01.02.709.00 is used for both Xbox 360 model 1414 and 1473.
    # Xbox sensors normally re-enumerate as 02BB; the Microsoft 1.8 driver family
    # also recognizes 02C3. Keep both runtime identities so discovery follows the
    # actual PnP topology instead of hard-coding one post-firmware PID.
    KinectUacRuntimeAudioHardwareIds = @('USB\VID_045E&PID_02BB','USB\VID_045E&PID_02C3')
    KinectUacRuntimeControlHardwareIds = @('USB\VID_045E&PID_02BB&MI_00','USB\VID_045E&PID_02C3&MI_00')
    KinectUacRuntimeSecurityHardwareIds = @('USB\VID_045E&PID_02BB&MI_01','USB\VID_045E&PID_02C3&MI_01')
    KinectUacRuntimeCaptureHardwareIds = @('USB\VID_045E&PID_02BB&MI_02','USB\VID_045E&PID_02C3&MI_02')

    # Primary aliases retained for scripts/contracts that need one canonical Xbox
    # identity. Runtime discovery itself uses the arrays above.
    Kinect1473RuntimeAudioHardwareId = 'USB\VID_045E&PID_02BB'
    Kinect1473RuntimeControlHardwareId = 'USB\VID_045E&PID_02BB&MI_00'
    Kinect1473RuntimeSecurityHardwareId = 'USB\VID_045E&PID_02BB&MI_01'
    Kinect1473RuntimeCaptureHardwareId = 'USB\VID_045E&PID_02BB&MI_02'

    # Single source of truth for installer lifecycle states. Physical USB
    # transports use inbox winusb.sys; no optional custom kernel audio endpoint
    # is installed by the standard package.
    InstallerStatePolicy = @{
        Exact = @('READY','PENDING','FAILED','SKIPPED')
        DynamicPrefixes = @('BLOCKED-CODE')
    }
}
