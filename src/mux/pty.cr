# src/mux/pty.cr
lib LibPty
  TIOCSWINSZ = 0x5414_u64
  TIOCGWINSZ = 0x5413_u64
  TIOCSCTTY  = 0x540E_u64
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
  fun setsid : LibC::PidT
  fun ioctl(fd : LibC::Int, request : UInt64, ...) : LibC::Int
  fun waitpid(pid : LibC::PidT, status : LibC::Int*, flags : LibC::Int) : LibC::PidT
end

module Term::Mux
  class PTY
    getter master : IO::FileDescriptor
    getter pid    : LibC::PidT

    def initialize(@master : IO::FileDescriptor, @pid : LibC::PidT)
    end

    def self.spawn(cols : Int32, rows : Int32, command : String, cwd : String,
                   xpixel : Int32 = 0, ypixel : Int32 = 0) : PTY
      master_fd = LibPty.posix_openpt(LibPty::O_RDWR | LibPty::O_NOCTTY)
      raise "posix_openpt failed" if master_fd < 0
      raise "grantpt failed" if LibPty.grantpt(master_fd) != 0
      raise "unlockpt failed" if LibPty.unlockpt(master_fd) != 0

      slave_name = LibPty.ptsname(master_fd)
      raise "ptsname failed" if slave_name.null?

      shell = ENV["SHELL"]? || "/bin/sh"
      shell = "/bin/sh" if shell.empty?

      argv : Array(String)
      path : String
      if command.empty?
        base = File.basename(shell)
        path = shell
        argv = ["-#{base}"]
      else
        path = "/bin/sh"
        argv = ["sh", "-c", command]
      end

      argv_buf = Pointer(Pointer(UInt8)).malloc(argv.size + 1)
      argv.each_with_index { |a, i| argv_buf[i] = a.to_unsafe }
      argv_buf[argv.size] = Pointer(UInt8).null

      ws = LibPty::Winsize.new
      ws.ws_row = rows.to_u16
      ws.ws_col = cols.to_u16
      ws.ws_xpixel = xpixel.to_u16
      ws.ws_ypixel = ypixel.to_u16

      pid = LibC.fork
      raise "fork failed" if pid < 0

      if pid == 0
        LibPty.setsid
        slave_fd = LibC.open(slave_name, LibPty::O_RDWR)
        if slave_fd >= 0
          LibPty.ioctl(slave_fd, LibPty::TIOCSCTTY, 0)
          LibPty.ioctl(slave_fd, LibPty::TIOCSWINSZ, pointerof(ws))
          LibC.dup2(slave_fd, 0)
          LibC.dup2(slave_fd, 1)
          LibC.dup2(slave_fd, 2)
          LibC.close(slave_fd) if slave_fd > 2
        end
        LibC.close(master_fd)
        LibC.setenv("TERM", "xterm-256color", 1)
        LibC.setenv("COLORTERM", "truecolor", 1)
        LibC.chdir(cwd) unless cwd.empty?
        LibC.execvp(path, argv_buf)
        LibC._exit(127)
      end

      LibPty.ioctl(master_fd, LibPty::TIOCSWINSZ, pointerof(ws))

      IO::FileDescriptor.set_blocking(master_fd, false)
      io = IO::FileDescriptor.new(master_fd)
      io.close_on_finalize = false
      new(io, pid)
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
      LibPty.waitpid(@pid, out status, 1) == 0
    end

    def foreground_pid : LibC::PidT
      pgid = 0
      LibPty.ioctl(@master.fd, LibPty::TIOCGPGRP, pointerof(pgid))
      pgid > 0 ? pgid : @pid
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

    def pid : LibC::PidT
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
