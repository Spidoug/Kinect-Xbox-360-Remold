# Native IP Camera Runtime — Version 1

`Kinect360RemoldCameraIp.exe` is a Windows user-mode service shipped inside the Kinect Remold runtime. It deliberately does **not** live in a `.sys` file and does not open the Kinect USB device.

## Data path

```text
Xbox NUI Camera (02AE)
        |
        v
Microsoft winusb.sys
        |
        v
Kinect360RemoldCameraBridge.exe
        |
        +--> Global\Kinect360RemoldFrame (NV12 RGB, seqlock/double buffer)
                 |                       |
                 |                       +--> Media Foundation virtual camera
                 |
                 +--> Kinect360RemoldCameraIp.exe
                          |
                          +--> /                 HTML viewer
                          +--> /stream.mjpg      MJPEG stream
                          +--> /snapshot.jpg     JPEG snapshot
                          +--> /status.json      runtime status
```

The IP service therefore shares the same RGB frame source as the Windows virtual camera. It never claims `\\.\pipe\Kinect360RemoldScanner`, never changes RGB/IR mode, and never competes for WinUSB endpoints.


## Camera activity and Kinect LED

An authenticated IP-camera client participates in the same camera-activity lease used by the Windows virtual camera and Scanner3D. While at least one authenticated HTTP client is active, `Kinect360RemoldCameraIp.exe` renews the `IpCamera` activity lease through `\\.\pipe\Kinect360RemoldControl`. The broker includes that lease in `cameraActivityMask` bit 2, so automatic LED policy keeps the Kinect LED solid green for the duration of the IP-camera use. Unauthenticated connection attempts do not claim the LED.

## Authentication and configuration

All routes require HTTP Basic authentication. The password is generated from the Windows CNG system RNG (`BCryptGenRandom`) during Install/Repair and is not compiled into source or binaries.

Configuration is written to:

```text
%ProgramData%\Kinect Xbox 360 Remold\camera-ip.ini
```

The file is created with an ACL restricted to LocalSystem and Administrators. The control panel (`KINECT.cmd`) can display the current URLs/credentials and rotate the password.

The product-wide deployment policy lives only in `build/Product.psd1` (`CameraIpPolicy`). Version 1 defaults to `0.0.0.0:8088`, eight encoded frames per second, JPEG quality 78 and at most eight simultaneous clients. The installer opens the port only on the Windows **Private** firewall profile and the local subnet only.

## Security boundary

HTTP Basic authentication prevents unauthenticated access but does not encrypt traffic. Version 1 therefore limits the automatically created firewall rule to Private networks. For untrusted networks or internet exposure, put the service behind a TLS reverse proxy/VPN instead of opening it directly to the public internet.

## RGB / IR hardware limitation

The Kinect 1414 has one physical video engine on endpoint `0x81`; RGB and raw IR are mutually exclusive. The native IP runtime follows the virtual-camera RGB transport. If `SynKinectSurveillance` switches endpoint `0x81` to IR while armed, the shared RGB frame stops advancing and the IP runtime reports the source as stale until RGB resumes. The service does not force a mode change because doing so would break the surveillance/scanner ownership rule.
