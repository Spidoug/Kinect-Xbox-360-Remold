class SurveillanceProtocol {
  static final String PIPE_NAME = "\\\\.\\pipe\\Kinect360RemoldScanner";
  static final String SOCKET_NAME = "/run/kinect360-remold/scanner.sock";
  static final int MAGIC = 0x43534D52;
  static final int FRAME_MAGIC = 0x46534D52;
  static final int VERSION = 1;
  static final int CMD_SUBSCRIBE_STREAMS = 1;

  static final int WIDTH = 640;
  static final int HEIGHT = 480;
  static final int MODE_RGB = 0;
  static final int MODE_IR = 1;
  static final int MODE_DEPTH = 2;
  static final int STREAM_RGB = 1;
  static final int STREAM_IR = 2;
  static final int STREAM_DEPTH = 4;
  static final int STREAM_RGB_DEPTH = STREAM_RGB | STREAM_DEPTH;
  static final int STREAM_IR_DEPTH = STREAM_IR | STREAM_DEPTH;

  static final int CAP_RGB_DEPTH_CONCURRENT = 1;
  static final int CAP_EXCLUSIVE_VIDEO_MODE = 2;
  static final int CAP_PROJECTOR_REFCOUNTED = 4;
  static final int REQUIRED_CAPABILITIES = CAP_EXCLUSIVE_VIDEO_MODE | CAP_PROJECTOR_REFCOUNTED;

  static final int PIXEL_NV12 = 1;
  static final int PIXEL_GRAY16 = 2;
  static final int PIXEL_DEPTH_MM16 = 3;
  static final int FLAG_DEVICE_CALIBRATED = 1;
  static final int FLAG_FRAME_RECOVERED = 2;
  static final int KNOWN_FRAME_FLAGS = FLAG_DEVICE_CALIBRATED | FLAG_FRAME_RECOVERED;

  static final int RGB_BYTES = WIDTH * HEIGHT * 3 / 2;
  static final int IR_BYTES = WIDTH * HEIGHT * 2;
  static final int DEPTH_BYTES = WIDTH * HEIGHT * 2;
  static final int MAX_PAYLOAD_BYTES = DEPTH_BYTES;
  static final int REPLY_BYTES = 32;
  static final int FRAME_HEADER_BYTES = 76;
}

int surveillanceMaskForMode(int mode) {
  return mode == SurveillanceProtocol.MODE_RGB ? SurveillanceProtocol.STREAM_RGB
       : mode == SurveillanceProtocol.MODE_IR ? SurveillanceProtocol.STREAM_IR
       : mode == SurveillanceProtocol.MODE_DEPTH ? SurveillanceProtocol.STREAM_DEPTH : 0;
}

int surveillanceExpectedFormatForMode(int mode) {
  return mode == SurveillanceProtocol.MODE_RGB ? SurveillanceProtocol.PIXEL_NV12
       : mode == SurveillanceProtocol.MODE_IR ? SurveillanceProtocol.PIXEL_GRAY16
       : mode == SurveillanceProtocol.MODE_DEPTH ? SurveillanceProtocol.PIXEL_DEPTH_MM16 : -1;
}

int surveillanceExpectedPayloadBytesForMode(int mode) {
  return mode == SurveillanceProtocol.MODE_RGB ? SurveillanceProtocol.RGB_BYTES
       : mode == SurveillanceProtocol.MODE_IR ? SurveillanceProtocol.IR_BYTES
       : mode == SurveillanceProtocol.MODE_DEPTH ? SurveillanceProtocol.DEPTH_BYTES : -1;
}
