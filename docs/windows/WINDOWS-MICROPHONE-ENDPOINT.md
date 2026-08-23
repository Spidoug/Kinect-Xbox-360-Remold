# Windows microphone endpoint

The previous custom SysVAD/WaveRT endpoint and experimental KMDF interval filter are removed from the default build.

The current architecture obtains a normal Windows capture endpoint without shipping any authored kernel audio code:

`Kinect 02AD → Microsoft winusb.sys → UACFirmware → Kinect 02BB MI_02 → inbox Microsoft USB Audio → WASAPI`

Because the runtime endpoint is created by Microsoft's USB Audio class driver, Windows applications can enumerate the Kinect capture device through the normal MMDevice/WASAPI stack. AudioBridge also consumes that endpoint and republishes a stable 4-channel S32LE pipe for the **Microphones** tab in `SynKinectStudio`.

This is intentionally different from adding ACX/PortCls/WaveRT code: there is no Remold `.sys` to trigger Code 52. The Remold Audio INF exists only for the temporary `02AD` WinUSB boot state and the user-mode bridge service.
