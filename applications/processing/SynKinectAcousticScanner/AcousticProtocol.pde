class AcousticProtocol {
  static final String PIPE="\\\\.\\pipe\\Kinect360RemoldAcoustic";
  static final String FALLBACK_PIPE="\\\\.\\pipe\\Kinect360RemoldAudio";
  static final String SOCKET="/run/kinect360-remold/acoustic.sock";
  static final String FALLBACK_SOCKET="/run/kinect360-remold/audio.sock";
  static final int MAGIC=0x414D4D52;
  static final int FRAME_MAGIC=0x464D4D52;
  static final int VERSION=1;
  static final int CMD_SUBSCRIBE=1;
  static final int SAMPLE_RATE=16000;
  static final int CHANNELS=4;
  static final int SAMPLES=256;
  static final int SAMPLE_FORMAT_S32LE=1;
  static final int BYTES_PER_SAMPLE=4;
  static final int PAYLOAD_BYTES=CHANNELS*SAMPLES*BYTES_PER_SAMPLE;
  static final int REQUEST_BYTES=16;
  static final int REPLY_BYTES=32;
  static final int HEADER_BYTES=48;
  static final int REQUIRED_CAPABILITIES=0x3;
  static final int VALID_CHANNEL_MASK=(1<<CHANNELS)-1;
}

class AcousticAudioFrame {
  long frameNumber,tickMs;
  int channelMask;
  int[][] samples=new int[AcousticProtocol.CHANNELS][AcousticProtocol.SAMPLES];
  float[] peak=new float[AcousticProtocol.CHANNELS];
  boolean valid(int channel){return channel>=0&&channel<AcousticProtocol.CHANNELS&&(channelMask&(1<<channel))!=0;}
}
