# bench/emitter_bench.cr
require "./bench_helper"

module EmitterBench
  alias Em = Term::Mux::Emitter

  CAPACITY = 256 * 1024
  TEXT     = "hello world"
  BLOB     = "x" * 32

  CASES = [
    {"literal text (11 B)",           256, ->(e : Em) { e.text(TEXT); nil }},
    {"single byte",                   256, ->(e : Em) { e.byte(0x41_u8); nil }},
    {"num, one digit",                256, ->(e : Em) { e.num(7); nil }},
    {"num, seven digits",             256, ->(e : Em) { e.num(1234567); nil }},
    {"static csi",                    256, ->(e : Em) { e.home; nil }},
    {"static csi, fixed params",      256, ->(e : Em) { e.sgr_reset; nil }},
    {"decset set",                    256, ->(e : Em) { e.alt_screen(true); nil }},
    {"decset pair via mode",          256, ->(e : Em) { e.mode(Term::Mux::Sequences::FOCUS_EVENTS, true); nil }},
    {"decset block",                  256, ->(e : Em) { e.synchronized { e.text(TEXT) }; nil }},
    {"csi 1 param",                   256, ->(e : Em) { e.sgr_fg(214); nil }},
    {"csi 1 param, default elided",   256, ->(e : Em) { e.cursor_up(1); nil }},
    {"csi 2 params, none default",    256, ->(e : Em) { e.cup(12, 40); nil }},
    {"csi 2 params, all default",     256, ->(e : Em) { e.cup(1, 1); nil }},
    {"csi 2 params, leading default", 256, ->(e : Em) { e.cup(1, 40); nil }},
    {"csi 2 params, wide values",     256, ->(e : Em) { e.cup(120, 4096); nil }},
    {"csi 3 params + marker",         256, ->(e : Em) { e.mouse_sgr(0, 120, 40); nil }},
    {"osc, st terminated",            256, ->(e : Em) { e.title("term-mux"); nil }},
    {"osc, utf-8 payload",            256, ->(e : Em) { e.title("héllo → world"); nil }},
    {"24-row synchronized frame",     8,   ->(e : Em) { frame(e) }},
  ]

  def self.frame(e : Em) : Nil
    e.synchronized do
      e.cup(1, 1)
      e.erase_display(2)
      row = 1
      while row <= 24
        e.cup(row, 1)
        e.sgr_fg(row + 30)
        e.erase_line(0)
        e.text("row content for the terminal frame benchmark")
        e.sgr_reset
        row += 1
      end
    end
    nil
  end

  def self.build(name : String, batch : Int32, emit : Proc(Em, Nil)) : Bench::Case
    probe = Em.new(CAPACITY)
    batch.times { emit.call(probe) }
    bytes = probe.size

    em = Em.new(CAPACITY)
    Bench::Case.new(name, batch, bytes, -> do
      i = 0
      while i < batch
        emit.call(em)
        i += 1
      end
      Bench.sink(em.size)
      em.reset
      nil
    end)
  end

  def self.growth : Bench::Case
    Bench::Case.new("growth from zero capacity", 1, 256 * BLOB.bytesize, -> do
      em = Em.new(0)
      i  = 0
      while i < 256
        em.text(BLOB)
        i += 1
      end
      Bench.sink(em.size)
      nil
    end)
  end

  def self.take : Bench::Case
    em = Em.new(CAPACITY)
    Bench::Case.new("write then take", 256, 256 * TEXT.bytesize, -> do
      i = 0
      while i < 256
        em.text(TEXT)
        Bench.sink(em.take.size)
        i += 1
      end
      nil
    end)
  end

  def self.run : Nil
    cases = CASES.map { |(name, batch, emit)| build(name, batch, emit) }
    cases << take
    cases << growth
    Bench.group("emitter", cases)
  end
end

EmitterBench.run
