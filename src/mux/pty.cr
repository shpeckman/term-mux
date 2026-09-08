# src/mux/pty.cr
lib LibPty
  TIOCSWINSZ = 0x5414_u64
  TIOCGWINSZ = 0x5413_u64
  TIOCGPGRP  = 0x540F_u64

  O_RDWR   =   0o2
  O_NOCTTY = 0o400

  struct Winsize
    ws_row    : UInt16
    ws_col    : UInt16
    ws_xpixel : UInt16
    ws_ypixel : UInt16
  end

  fun posix_openpt(flags : LibC::Int) : LibC::Int
  fun grantpt(fd : LibC::Int) : LibC::Int
  fun unlockpt(fd : LibC::Int) : LibC::Int
  fun ptsname(fd : LibC::Int) : LibC::Char*
  fun ioctl(fd : LibC::Int, request : UInt64, ...) : LibC::Int
end

module Term::Mux
  class PTY
    SETSID        = "setsid"
    DEFAULT_SHELL = "/bin/sh"
    CHILD_ENV     = {"TERM" => "xterm-256color", "COLORTERM" => "truecolor"}

    getter master  : IO::FileDescriptor
    getter process : Process

    def initialize(@master : IO::FileDescriptor, @process : Process)
    end

    def self.spawn(cols : Int32, rows : Int32, command : String, cwd : String,
                   xpixel : Int32 = 0, ypixel : Int32 = 0) : PTY
      master_fd = LibPty.posix_openpt(LibPty::O_RDWR | LibPty::O_NOCTTY)
      raise "posix_openpt failed" if master_fd < 0

      master = IO::FileDescriptor.new(master_fd, blocking: false)
      master.close_on_exec = true

      process = begin
        start(master_fd, cols, rows, xpixel, ypixel, command, cwd)
      rescue ex
        master.close
        raise ex
      end

      new(master, process)
    end

    private def self.start(master_fd : Int32, cols : Int32, rows : Int32,
                           xpixel : Int32, ypixel : Int32,
                           command : String, cwd : String) : Process
      raise "grantpt failed" if LibPty.grantpt(master_fd) != 0
      raise "unlockpt failed" if LibPty.unlockpt(master_fd) != 0

      name = LibPty.ptsname(master_fd)
      raise "ptsname failed" if name.null?
      slave_name = String.new(name)

      ws = winsize(cols, rows, xpixel, ypixel)
      raise "TIOCSWINSZ failed" if LibPty.ioctl(master_fd, LibPty::TIOCSWINSZ, pointerof(ws)) != 0

      slave_fd = LibC.open(slave_name, LibPty::O_RDWR | LibPty::O_NOCTTY)
      raise "open #{slave_name} failed" if slave_fd < 0

      slave = IO::FileDescriptor.new(slave_fd)
      begin
        Process.new(SETSID, child_args(command),
          env: CHILD_ENV,
          input: slave, output: slave, error: slave,
          chdir: cwd.empty? ? nil : cwd)
      ensure
        slave.close
      end
    end

    private def self.child_args(command : String) : Array(String)
      args = ["--ctty", "--fork", "--wait"]
      if command.empty?
        shell = ENV["SHELL"]?
        shell = DEFAULT_SHELL if shell.nil? || shell.empty?
        args << shell << "-l"
      else
        args << DEFAULT_SHELL << "-c" << command
      end
      args
    end

    private def self.winsize(cols : Int32, rows : Int32, xpixel : Int32, ypixel : Int32) : LibPty::Winsize
      ws = LibPty::Winsize.new
      ws.ws_row = rows.to_u16
      ws.ws_col = cols.to_u16
      ws.ws_xpixel = xpixel.to_u16
      ws.ws_ypixel = ypixel.to_u16
      ws
    end

    def pid : Int64
      @process.pid
    end

    def resize(cols : Int32, rows : Int32) : Nil
      ws = LibPty::Winsize.new
      LibPty.ioctl(@master.fd, LibPty::TIOCGWINSZ, pointerof(ws))
      ws.ws_row = rows.to_u16
      ws.ws_col = cols.to_u16
      LibPty.ioctl(@master.fd, LibPty::TIOCSWINSZ, pointerof(ws))
    end

    def write(bytes : Bytes) : Nil
      @master.write(bytes)
      @master.flush
    rescue IO::Error
    end

    def read(bytes : Bytes) : Int32
      @master.read(bytes)
    end

    def alive? : Bool
      !@process.terminated?
    end

    def foreground_pid : Int32
      pgid = 0
      LibPty.ioctl(@master.fd, LibPty::TIOCGPGRP, pointerof(pgid))
      pgid > 0 ? pgid : @process.pid.to_i32
    end

    def terminate : Nil
      @process.terminate
    rescue
    end

    def wait : Process::Status
      @process.wait
    end

    def close : Nil
      @master.close rescue nil
    end
  end

  class PtyHost
    getter pty  : PTY
    getter dead : Bool = false

    def initialize(cols : Int32, rows : Int32, command : String, cwd : String,
                   @on_output : Proc(Bytes, Nil)? = nil,
                   @on_dead : Proc(Nil)? = nil,
                   xpixel : Int32 = 0, ypixel : Int32 = 0)
      @pty = PTY.spawn(cols, rows, command, cwd, xpixel: xpixel, ypixel: ypixel)
      spawn_reader
    end

    def pid : Int64
      @pty.pid
    end

    def current_command : String
      fg = @pty.foreground_pid
      File.read("/proc/#{fg}/comm").strip
    rescue
      ""
    end

    def resize(cols : Int32, rows : Int32) : Nil
      return if cols < 2 || rows < 1
      @pty.resize(cols, rows)
    end

    def write(bytes : Bytes) : Nil
      @pty.write(bytes)
    end

    def write(str : String) : Nil
      write(str.to_slice)
    end

    private def spawn_reader : Nil
      host = self
      spawn do
        buf = Bytes.new(16384)
        loop do
          n = host.pty.read(buf)
          break if n <= 0
          host.notify_output(buf[0, n])
        end
        host.mark_dead
      rescue IO::Error
        host.mark_dead
      end
    end

    protected def notify_output(bytes : Bytes) : Nil
      @on_output.try &.call(bytes)
    end

    protected def mark_dead : Nil
      return if @dead
      @dead = true
      @on_dead.try &.call
    end

    def close : Nil
      @pty.close
    end
  end
end
