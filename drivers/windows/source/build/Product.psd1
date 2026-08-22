@{
    Name        = 'Kinect Xbox 360 Remold'
    Version     = '1'
    VersionQuad = '1.0.0.0'
    DriverDate  = '08/21/2026'
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
            Source = 'Microsoft Kinect for Windows SDK Beta 2 x86'
            Version = '1.0.0.45'
            Url = 'https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi'
            KnownMd5 = @('945806927702b2c47c32125ab9a80344','40764fe9e00911bda5095e5be777e311')
            ExpectedBytes = 21823488
            FilePattern = 'UACFirmware*'
            FirmwareFileName = 'UACFirmware.C9C6E852_35A3_41DC_A57D_BDDEB43DFD04'
        }
    }

    MinimumWindowsBuild = 22000
    StartupTiltDegrees = 6
    TiltMinDegrees = -27
    TiltMaxDegrees = 27

    # Version 1 hardware-behavior policy. Build scripts materialize these values
    # into generated native headers so LED/motor timing is not duplicated in C++.
    CameraActivityHeartbeatMs = 750
    CameraActivityLeaseMs = 2000
    CameraLedPolicy = @{
        ActiveRefreshMs = 1000
        IdleRefreshMs = 2000
        IdleFlashMs = 120
        IdleOffMs = 4000
        PollMs = 25
        RetryMs = 250
    }
    ConnectionChirpPolicy = @{
        Enabled = $true
        StepHalfDegrees = 2
        PulseMs = 18
        Cycles = 2
        CooldownMs = 4000
    }
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
        @{ Key='Motor';   DisplayName='Xbox NUI Motor transport';      Inf='drivers\nui\Kinect360RemoldNui.inf';       Cat='drivers\nui\Kinect360RemoldNui.cat'; HardwareId='USB\VID_045E&PID_02B0' },
        @{ Key='Camera';  DisplayName='Xbox NUI Camera transport';     Inf='drivers\camera\Kinect360RemoldCamera.inf'; Cat='drivers\camera\Kinect360RemoldCamera.cat'; HardwareId='USB\VID_045E&PID_02AE' },
        @{ Key='Audio';   DisplayName='Xbox NUI Audio transport';      Inf='drivers\audio\Kinect360RemoldAudio.inf';    Cat='drivers\audio\Kinect360RemoldAudio.cat'; HardwareId='USB\VID_045E&PID_02AD' }
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

    # Single source of truth for installer lifecycle states. Physical USB
    # transports use inbox winusb.sys; no optional custom kernel audio endpoint
    # is installed by the standard package.
    InstallerStatePolicy = @{
        Exact = @('READY','PENDING','FAILED','SKIPPED')
        DynamicPrefixes = @('BLOCKED-CODE')
    }
}
