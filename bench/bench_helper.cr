# bench/bench_helper.cr
require "../src/term-mux"

Term::Mux::Emitter.define do
  decset alt_screen, mode: 1049
  decset cursor_visible, mode: 25
  decset bracketed_paste, mode: 2004
  decset focus_events, mode: 1004
  decset synchronized, mode: 2026, block: true

  csi cup(row, col), final: 'H', defaults: {1, 1}
  csi cursor_up(rows), final: 'A', defaults: {1}
  csi erase_line(target), final: 'K', defaults: {0}
  csi erase_display(target), final: 'J', defaults: {0}
  csi mouse_sgr(button, x, y), marker: '<', final: 'M'
  csi sgr_fg(color), final: 'm'
  csi sgr_reset, final: 'm', params: {0}
  csi home, final: 'H'

  osc title(text), code: 0
end

module Bench
  WARMUP    = 300.milliseconds
  DURATION  = 2.seconds
  MAX_BATCH =        4096
  TARGET_NS = 2_000_000.0
  MIB       = 1_048_576.0

  record Case, name : String, units : Int32, bytes : Int32, run : Proc(Nil)

  @@sink = 0_u64

  def self.sink(value : Int32) : Nil
    @@sink &+= value.to_u64
  end

  def self.banner : Nil
    puts "term-mux benchmarks"
    puts "crystal #{Crystal::VERSION} | term-mux #{Term::Mux::VERSION}"
    {% unless flag?(:release) %}
      puts "warning: not compiled with --release, numbers are meaningless"
    {% end %}
  end

  def self.finish : Nil
    puts
    puts "sink #{@@sink}"
  end

  def self.group(title : String, cases : Array(Case)) : Nil
    puts
    puts title
    puts "-" * 76
    printf("%-34s %14s %12s %12s\n", "case", "unit/s", "ns/unit", "MiB/s")
    cases.each do |c|
      calls, elapsed = measure(c.run)
      report(c, calls, elapsed)
    end
  end

  private def self.measure(run : Proc(Nil)) : {Int64, Time::Span}
    batch = calibrate(run)
    spin(run, batch, WARMUP)
    spin(run, batch, DURATION)
  end

  private def self.calibrate(run : Proc(Nil)) : Int32
    run.call
    start = Time.instant
    run.call
    ns = start.elapsed.total_nanoseconds
    return MAX_BATCH if ns <= 0
    (TARGET_NS / ns).clamp(1.0, MAX_BATCH.to_f).to_i
  end

  private def self.spin(run : Proc(Nil), batch : Int32, duration : Time::Span) : {Int64, Time::Span}
    calls    = 0_i64
    start    = Time.instant
    deadline = start + duration
    loop do
      i = 0
      while i < batch
        run.call
        i += 1
      end
      calls += batch
      break if Time.instant >= deadline
    end
    {calls, start.elapsed}
  end

  private def self.report(c : Case, calls : Int64, elapsed : Time::Span) : Nil
    secs  = elapsed.total_seconds
    units = calls * c.units
    printf("%-34s %14.0f %12.1f %12.1f\n",
      c.name,
      units / secs,
      secs * 1e9 / units,
      (calls * c.bytes) / secs / MIB)
  end

  module Payloads
    TARGET = 64 * 1024

    def self.build(& : String::Builder ->) : Bytes
      io = String::Builder.new(TARGET + 8192)
      while io.bytesize < TARGET
        yield io
      end
      io.to_s.to_slice
    end

    PLAIN = build do |io|
      io << "the quick brown fox jumps over the lazy dog 0123456789\r\n"
    end

    CSI = build do |io|
      row = 1
      while row <= 24
        io << "\e[" << row << ";1H\e[K" << "line " << row << " of a full screen redraw"
        row += 1
      end
      io << "\e[H"
    end

    SGR = build do |io|
      i = 0
      while i < 16
        io << "\e[38;5;" << (i * 16) << "m" << "swatch" << "\e[0m"
        i += 1
      end
      io << "\r\n"
    end

    MIXED = build do |io|
      io << "\e[?2026h\e[H\e[2J"
      row = 1
      while row <= 8
        io << "\e[" << row << ";1H"
        io << "\e[1;32m" << "drwxr-xr-x" << "\e[0m  "
        io << "\e[34m" << "directory-" << row << "\e[39m"
        io << "  " << (row * 4096) << " bytes\r\n"
        row += 1
      end
      io << "\e]0;term-mux bench\e\\\e[?2026l"
    end

    KEYS = build do |io|
      io << "\eOA\eOB\e[C\e[D"
      io << "printf hello world"
      io << "\e[<0;10;20M\e[<0;10;20m"
      io << "\e[?1004h\e[?1004l"
      io << "\r"
    end

    STRINGS = build do |io|
      io << "\e]0;a reasonably long window title\e\\"
      io << "\e]52;c;bWFueSBieXRlcyBvZiBiYXNlNjQgY2xpcGJvYXJkIGRhdGE=\a"
      io << "\ePq#0;2;0;0;0#0~~@@vv@@~~@@~~$\e\\"
      io << "\e_Ga=T,f=32,s=10,v=10;AAAAAAAAAAAAAAAA\e\\"
    end

    PASTE = build do |io|
      io << "\e[200~"
      i = 0
      while i < 64
        io << "a pasted line of text with no escapes at all\n"
        i += 1
      end
      io << "\e[201~"
    end
  end
end

Bench.banner
