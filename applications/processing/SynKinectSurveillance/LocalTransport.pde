class LocalTransport implements Closeable {
  RandomAccessFile windowsPipe;
  SocketChannel unixChannel;
  InputStream input;
  OutputStream output;

  static boolean isLinux() {
    String os=System.getProperty("os.name","").toLowerCase(Locale.ROOT);
    return os.contains("linux");
  }

  static LocalTransport open(String windowsPath,String linuxPath)throws IOException {
    LocalTransport t=new LocalTransport();
    if(isLinux()) {
      t.unixChannel=SocketChannel.open(StandardProtocolFamily.UNIX);
      t.unixChannel.connect(UnixDomainSocketAddress.of(linuxPath));
      t.input=Channels.newInputStream(t.unixChannel);
      t.output=Channels.newOutputStream(t.unixChannel);
    } else {
      t.windowsPipe=new RandomAccessFile(windowsPath,"rw");
    }
    return t;
  }

  void write(byte[] data)throws IOException {
    if(windowsPipe!=null) { windowsPipe.write(data); return; }
    output.write(data); output.flush();
  }
  void readFully(byte[] data)throws IOException {
    if(windowsPipe!=null) { windowsPipe.readFully(data); return; }
    int offset=0;
    while(offset<data.length) {
      int n=input.read(data,offset,data.length-offset);
      if(n<0)throw new EOFException("local transport closed");
      offset+=n;
    }
  }
  public void close()throws IOException {
    IOException failure=null;
    if(unixChannel!=null) {
      try { unixChannel.close(); } catch(IOException e) { failure=e; }
    }
    try { if(windowsPipe!=null)windowsPipe.close(); } catch(IOException e) { if(failure==null)failure=e; }
    if(failure!=null)throw failure;
  }
}
