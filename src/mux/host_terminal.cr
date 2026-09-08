# src/mux/host_terminal.cr
module Term::Mux
  class HostTerminal
    DEFAULT_COLS = 80
    DEFAULT_ROWS = 24

    BELL = Bytes[0x07_u8]

    struct Size
      getter cols   : Int32
      getter rows   : Int32
      getter xpixel : Int32
      getter ypixel : Int32

      def initialize(@cols : Int32, @rows : Int32, @xpixel : Int32 = 0, @ypixel : Int32 = 0)
      end
    end

    getter input      : IO::FileDescriptor
    getter output     : IO::FileDescriptor
    getter? raw       : Bool = false
    property setup    : Bytes
    property teardown : Bytes

    @saved    : LibC::Termios = LibC::Termios.new
    @handlers : Array(Size -> Nil)
    @trapped  : Bool          = false

    def initialize(@input : IO::FileDescriptor = STDIN, @output : IO::FileDescriptor = STDOUT,
                   @setup : Bytes = Bytes.empty, @teardown : Bytes = Bytes.empty)
      @handlers = [] of Size -> Nil
    end

    def self.size_of(fd : Int32) : Size?
      ws = LibPty::Winsize.new
      return nil unless LibPty.ioctl(fd, LibPty::TIOCGWINSZ, pointerof(ws)) == 0
      return nil unless ws.ws_col > 0 && ws.ws_row > 0
      Size.new(ws.ws_col.to_i32, ws.ws_row.to_i32, ws.ws_xpixel.to_i32, ws.ws_ypixel.to_i32)
    end

    def self.env_size : Size
      Size.new(ENV["COLUMNS"]?.try(&.to_i?) || DEFAULT_COLS,
        ENV["LINES"]?.try(&.to_i?) || DEFAULT_ROWS)
    end

    def size : Size
      HostTerminal.size_of(@output.fd) || HostTerminal.size_of(@input.fd) || HostTerminal.env_size
    end

    def raw! : Bool
      return true if @raw
      return false unless LibC.tcgetattr(@input.fd, pointerof(@saved)) == 0
      termios = @saved
      LibC.cfmakeraw(pointerof(termios))
      return false unless LibC.tcsetattr(@input.fd, LibC::TCSANOW, pointerof(termios)) == 0
      @raw = true
    end

    def restore : Nil
      return unless @raw
      LibC.tcsetattr(@input.fd, LibC::TCSANOW, pointerof(@saved))
      @raw = false
    end

    def read(buf : Bytes) : Int32
      @input.read(buf)
    end

    def write(bytes : Bytes) : Nil
      return if bytes.empty?
      @output.write(bytes)
      @output.flush
    end

    def write(str : String) : Nil
      write(str.to_slice)
    end

    def bell : Nil
      write(BELL)
    end

    def on_resize(&handler : Size -> Nil) : Nil
      @handlers << handler
      return if @trapped
      @trapped = true
      Signal::WINCH.trap { notify_resize }
    end

    def open : Nil
      raw!
      write(@setup)
    end

    def close : Nil
      write(@teardown)
      restore
      if @trapped
        Signal::WINCH.reset
        @trapped = false
      end
      @handlers.clear
    end

    def session(&)
      open
      yield self
    ensure
      close
    end

    private def notify_resize : Nil
      current = size
      @handlers.each &.call(current)
    end
  end
end
