# src/mux/client.cr
class Term::Mux::Client
  ENABLE_INPUT  = "\e[?1049h\e[?2004;1003;1016;1004;2048;2033;2031h\e[=31u"
  DISABLE_INPUT = "\e[=0u\e[?2004;1003;1016;1004;2048;2033;2031l\e[0m\e[?25h\e[?1049l"

  @io      : UNIXSocket?
  @running : Bool = true

  def initialize(@socket_path : String, @daemon_path : String? = nil)
  end

  def send_command(argv : Array(String)) : {Bool, String}
    io = connect_or_fail
    return {false, "no server running"} unless io
    Protocol.write(io, Protocol::Kind::Command, Protocol.encode_argv(argv))
    loop do
      msg = Protocol.read(io)
      return {false, "server closed connection"} unless msg
      kind, payload = msg
      if kind.reply?
        buf  = IO::Memory.new(payload)
        ok   = buf.read_byte.not_nil! != 0_u8
        text = Protocol.read_str(buf)
        return {ok, text}
      end
    end
  rescue ex : IO::Error
    {false, ex.message || "io error"}
  ensure
    io.try &.close rescue nil
  end

  def attach(info : Protocol::AttachInfo) : Int32
    io = connect_or_fail
    return 1 unless io
    @io = io

    old_termios = LibC::Termios.new
    raw         = false
    if LibC.tcgetattr(0, pointerof(old_termios)) == 0
      raw_termios = old_termios
      LibC.cfmakeraw(pointerof(raw_termios))
      if LibC.tcsetattr(0, LibC::TCSANOW, pointerof(raw_termios)) == 0
        raw = true
      end
    end

    STDOUT.write(ENABLE_INPUT.to_slice)
    STDOUT.flush

    exit_code = 0
    begin
      Protocol.write(io, Protocol::Kind::Attach, info.encode)

      spawn stdin_loop(io)

      Signal::WINCH.trap do
        c, r, _, _ = self.class.tty_size
        @io.try { |s| Protocol.write(s, Protocol::Kind::Resize, Protocol.encode_xy(c, r)) rescue nil }
      end

      while @running
        msg = Protocol.read(io)
        break unless msg
        kind, payload = msg
        case kind
        when .render?
          STDOUT.write(payload)
          STDOUT.flush
        when .bell?
          STDOUT.write_byte(0x07_u8)
          STDOUT.flush
        when .exit?
          exit_code = payload.size > 0 ? payload[0].to_i32 : 0
          @running  = false
        else
        end
      end
    ensure
      if raw
        LibC.tcsetattr(0, LibC::TCSANOW, pointerof(old_termios))
      end
      STDOUT.write(DISABLE_INPUT.to_slice)
      STDOUT.flush
      io.close rescue nil
    end

    exit_code
  end

  private def connect_or_fail : UNIXSocket?
    ensure_server
    UNIXSocket.new(@socket_path)
  rescue
    nil
  end

  private def ensure_server : Nil
    return if File.exists?(@socket_path) && server_responds?(@socket_path)
    daemon = @daemon_path
    return unless daemon && File.exists?(daemon)

    null_r = File.open("/dev/null", "r")
    null_w = File.open("/dev/null", "w")
    Process.new(daemon, input: null_r, output: null_w, error: null_w)

    50.times do
      sleep 50.milliseconds
      return if File.exists?(@socket_path) && server_responds?(@socket_path)
    end
  end

  private def server_responds?(path : String) : Bool
    sock = UNIXSocket.new(path)
    sock.close
    true
  rescue
    false
  end

  private def stdin_loop(io : UNIXSocket) : Nil
    buf = Bytes.new(4096)
    while @running
      n = STDIN.read(buf)
      break if n <= 0
      Protocol.write(io, Protocol::Kind::Input, buf[0, n])
    end
  rescue IO::Error
  end

  def self.tty_size : {Int32, Int32, Int32, Int32}
    ws = LibPty::Winsize.new
    if LibPty.ioctl(1, LibPty::TIOCGWINSZ, pointerof(ws)) == 0 && ws.ws_col > 0 && ws.ws_row > 0
      {ws.ws_col.to_i32, ws.ws_row.to_i32, ws.ws_xpixel.to_i32, ws.ws_ypixel.to_i32}
    else
      {(ENV["COLUMNS"]? || "80").to_i, (ENV["LINES"]? || "24").to_i, 0, 0}
    end
  end
end
