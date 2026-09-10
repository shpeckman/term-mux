# src/mux/middleman.cr
class Term::Mux::Middleman
  TICK = 8.milliseconds

  getter input  : Term::Seq::InputFilter
  getter output : Term::Seq::OutputFilter

  @pty_host : PtyHost?
  @running  : Bool = false

  def initialize(@command : String = "", @cwd : String = "",
                 @setup : Bytes = Bytes.empty, @teardown : Bytes = Bytes.empty,
                 escape_ticks : Int32 = 2,
                 @host_in     : IO    = STDIN, @host_out : IO = STDOUT)
    @input          = Term::Seq::InputFilter.new(escape_ticks)
    @output         = Term::Seq::OutputFilter.new
    @emitter        = Term::Seq::Emitter.new
    @input_mutex    = Mutex.new
    @host_out_mutex = Mutex.new
    @child_in_mutex = Mutex.new
    @pty_host       = nil
  end

  def run : Int32
    old_termios = LibC::Termios.new
    raw         = false
    if LibC.tcgetattr(0, pointerof(old_termios)) == 0
      raw_termios = old_termios
      LibC.cfmakeraw(pointerof(raw_termios))
      raw = LibC.tcsetattr(0, LibC::TCSANOW, pointerof(raw_termios)) == 0
    end

    write_terminal(@setup)

    begin
      cols, rows, xpixel, ypixel = Client.tty_size
      dead = Channel(Nil).new(1)
      host = PtyHost.new(cols, rows, @command, @cwd,
        on_output: ->(bytes : Bytes) { write_host(@output.feed(bytes)) },
        on_dead: -> { dead.send(nil) },
        xpixel: xpixel, ypixel: ypixel)
      @pty_host = host

      @running = true
      spawn stdin_loop
      spawn tick_loop

      Signal::WINCH.trap do
        c, r, _, _ = Client.tty_size
        @pty_host.try &.resize(c, r)
      end

      dead.receive
      @running = false
      exit_status(host.pty.wait)
    ensure
      @running = false
      if raw
        LibC.tcsetattr(0, LibC::TCSANOW, pointerof(old_termios))
      end
      write_terminal(@teardown)
      @pty_host.try &.close
    end
  end

  def inject_host(& : Term::Seq::Emitter ->) : Nil
    yield @emitter
    write_host(@emitter.take)
  end

  def inject_child(& : Term::Seq::Emitter ->) : Nil
    yield @emitter
    write_child(@emitter.take)
  end

  def write_host(bytes : Bytes) : Nil
    return if bytes.empty?
    @host_out_mutex.synchronize do
      @host_out.write(bytes)
      @host_out.flush
    end
  end

  def write_child(bytes : Bytes) : Nil
    return if bytes.empty?
    host = @pty_host
    return unless host
    @child_in_mutex.synchronize { host.write(bytes) }
  end

  private def stdin_loop : Nil
    buf = Bytes.new(4096)
    while @running
      n = @host_in.read(buf)
      break if n <= 0
      res = @input_mutex.synchronize { @input.feed(buf[0, n]) }
      write_child(res)
    end
  rescue IO::Error
  end

  private def tick_loop : Nil
    while @running
      sleep TICK
      res = @input_mutex.synchronize { @input.tick }
      write_child(res)
    end
  end

  private def write_terminal(bytes : Bytes) : Nil
    return if bytes.empty?
    @host_out_mutex.synchronize do
      @host_out.write(bytes)
      @host_out.flush
    end
  end

  private def exit_status(status : Process::Status) : Int32
    if code = status.exit_code?
      code
    elsif signal = status.exit_signal?
      128 + signal.value
    else
      1
    end
  end
end
