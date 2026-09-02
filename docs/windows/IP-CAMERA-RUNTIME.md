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

The IP service therefore shares the same RGB frame source as the Windows virtual camera. It never claims any `\\.\pipe\Kinect360RemoldScanner-<device-id>` endpoint, never changes RGB/IR mode, and never competes for WinUSB endpoints.


## Physical-control isolation

The IP-camera service is a read-only consumer of the shared RGB publication. It does not send motor/LED activity heartbeats to the Broker and cannot change physical Kinect control state. Authentication governs network access only.

## Authentication and configuration

All routes require HTTP Basic authentication. The password is generated from the Windows CNG system RNG (`BCryptGenRandom`) during Install/Reinstall and is not compiled into source or binaries.

Configuration is written to:

```text
%ProgramData%\Kinect Xbox 360 Remold\camera-ip.ini
```

The file is created with an ACL restricted to LocalSystem and Administrators. The control panel (`KINECT.cmd`) can display the current URLs/credentials and rotate the password.

The product-wide deployment policy lives only in `build/Product.psd1` (`CameraIpPolicy`). Version 1 defaults to `0.0.0.0:8088`, eight encoded frames per second, JPEG quality 78 and at most eight simultaneous clients. The installer opens the port only on the Windows **Private** firewall profile and the local subnet only.

## Security boundary

HTTP Basic authentication prevents unauthenticated access but does not encrypt traffic. Version 1 therefore limits the automatically created firewall rule to Private networks. For untrusted networks or internet exposure, put the service behind a TLS reverse proxy/VPN instead of opening it directly to the public internet.

## RGB / IR hardware limitation

The Kinect 1414 has one physical video engine on endpoint `0x81`; RGB and raw IR are mutually exclusive. The V1 native IP runtime follows the registry-primary Kinect RGB transport. SynKinect Studio Surveillance uses RGB only in normal light and IR only in low light; it never subscribes Depth. RGB and IR remain mutually exclusive on endpoint `0x81`; while Surveillance is foreground it owns this day/night switch. When the user leaves Surveillance, it releases IR and returns to RGB so Scanner, Interactivity, virtual-camera and IP-camera RGB consumers are not held behind a background IR subscription.
