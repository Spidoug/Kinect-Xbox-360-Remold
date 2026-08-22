class ScannerProtocol {
  static final String PIPE_NAME = "\\\\.\\pipe\\Kinect360RemoldScanner";
  static final String SOCKET_NAME = "/run/kinect360-remold/scanner.sock";
  static final int MAGIC = 0x43534D52;
  static final int FRAME_MAGIC = 0x46534D52;
  static final int VERSION = 1;
  static final int CMD_SUBSCRIBE_STREAMS = 1;

  static final int WIDTH = 640;
  static final int HEIGHT = 480;
  static final int MODE_RGB = 0;
  static final int MODE_DEPTH = 2;
  static final int STREAM_RGB = 1;
  static final int STREAM_DEPTH = 4;
  static final int STREAM_SESSION = STREAM_RGB | STREAM_DEPTH;

  static final int CAP_RGB_DEPTH_CONCURRENT = 1;
  static final int CAP_EXCLUSIVE_VIDEO_MODE = 2;
  static final int CAP_PROJECTOR_REFCOUNTED = 4;
  static final int CAP_ACCELEROMETER = 8;
  static final int REQUIRED_CAPABILITIES = CAP_RGB_DEPTH_CONCURRENT | CAP_EXCLUSIVE_VIDEO_MODE | CAP_PROJECTOR_REFCOUNTED;

  static final int PIXEL_NV12 = 1;
  static final int PIXEL_DEPTH_MM16 = 3;
  static final int FLAG_DEVICE_CALIBRATED = 1;
  static final int FLAG_FRAME_RECOVERED = 2;
  static final int KNOWN_FRAME_FLAGS = FLAG_DEVICE_CALIBRATED | FLAG_FRAME_RECOVERED;

  static final int RGB_BYTES = WIDTH * HEIGHT * 3 / 2;
  static final int DEPTH_BYTES = WIDTH * HEIGHT * 2;
  static final int MAX_PAYLOAD_BYTES = DEPTH_BYTES;
  static final int REPLY_BYTES = 32;
  static final int FRAME_HEADER_BYTES = 76;

}

// Processing merges PDE tabs into the sketch class. ScannerProtocol is therefore
// an inner type and must contain constants only; executable protocol helpers
// remain sketch methods in this same tab instead of illegal static methods.
int scannerMaskForMode(int mode) {
  return mode == ScannerProtocol.MODE_RGB ? ScannerProtocol.STREAM_RGB
       : mode == ScannerProtocol.MODE_DEPTH ? ScannerProtocol.STREAM_DEPTH : 0;
}

int scannerExpectedFormatForMode(int mode) {
  return mode == ScannerProtocol.MODE_RGB ? ScannerProtocol.PIXEL_NV12
       : mode == ScannerProtocol.MODE_DEPTH ? ScannerProtocol.PIXEL_DEPTH_MM16 : -1;
}

int scannerExpectedPayloadBytesForMode(int mode) {
  return mode == ScannerProtocol.MODE_RGB ? ScannerProtocol.RGB_BYTES
       : mode == ScannerProtocol.MODE_DEPTH ? ScannerProtocol.DEPTH_BYTES : -1;
}
