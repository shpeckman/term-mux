# bench/input_filter_bench.cr
require "./bench_helper"

module InputFilterBench
  alias Filter = Term::Mux::InputFilter
  alias Disp = Term::Mux::Disposition

  record Scenario, name : String, payload : Bytes, chunk : Int32, setup : Proc(Filter, Nil)

  NO_RULES = ->(f : Filter) { nil }

  BYTE_RULE = ->(f : Filter) do
    f.on_byte(0x02_u8) { Disp.drop }
    nil
  end

  FULL_RULES = ->(f : Filter) do
    f.on_byte(0x02_u8) { Disp.drop }
    f.on_byte(0x14_u8) { Disp.drop }
    f.on(Term::Mux::Sequences::FOCUS_EVENTS) { Disp.pass }
    f.on(Term::Mux::Sequences::ALT_SCREEN) { Disp.pass }
    f.on(Term::Mux::Sequences::MOUSE_SGR) { Disp.pass }
    f.on(Term::Mux::Sequences::CUP) { Disp.pass }
    f.on_ss3('A') { Disp.pass }
    f.on_esc('b') { Disp.drop }
    f.on_osc(0) { Disp.pass }
    f.on_osc { Disp.drop }
    f.on_dcs('q') { Disp.pass }
    f.on_apc { Disp.drop }
    nil
  end

  KITTY_RULES = ->(f : Filter) do
    f.on_csi('u') { |t| Bench.sink(t.param(0) + t.sub(0, 1) + t.param(1, 1)); Disp.pass }
    f.on_csi('~') { |t| Bench.sink(t.param(0)); Disp.pass }
    f.on_csi('t') { |t| Bench.sink(t.param(0)); Disp.pass }
    f.on_csi('A') { Disp.pass }
    f.on_csi('B') { Disp.pass }
    f.on_csi('I') { Disp.pass }
    f.on_csi('O') { Disp.pass }
    f.on_csi('M', marker: '<') { |t| Bench.sink(t.param(1)); Disp.pass }
    f.on_csi('m', marker: '<') { |t| Bench.sink(t.param(1)); Disp.pass }
    nil
  end

  CATCH_ALL = ->(f : Filter) do
    f.on_csi { Disp.pass }
    f.on_ss3 { Disp.pass }
    f.on_esc { Disp.pass }
    f.on_osc { Disp.pass }
    f.on_dcs { Disp.pass }
    f.on_apc { Disp.pass }
    nil
  end

  PASTE_RULES = ->(f : Filter) do
    f.on_paste { |t| Bench.sink(t.bytes.size); Disp.pass }
    nil
  end

  SCENARIOS = [
    Scenario.new("plain text, no rules", Bench::Payloads::PLAIN, 0, NO_RULES),
    Scenario.new("plain text, one byte rule", Bench::Payloads::PLAIN, 0, BYTE_RULE),
    Scenario.new("keys, no rules", Bench::Payloads::KEYS, 0, NO_RULES),
    Scenario.new("keys, full rules", Bench::Payloads::KEYS, 0, FULL_RULES),
    Scenario.new("keys, 16 B chunks", Bench::Payloads::KEYS, 16, FULL_RULES),
    Scenario.new("keys, 1 B chunks", Bench::Payloads::KEYS, 1, FULL_RULES),
    Scenario.new("kitty keys, no rules", Bench::Payloads::KITTY, 0, NO_RULES),
    Scenario.new("kitty keys, event rules", Bench::Payloads::KITTY, 0, KITTY_RULES),
    Scenario.new("kitty keys, 16 B chunks", Bench::Payloads::KITTY, 16, KITTY_RULES),
    Scenario.new("kitty keys, catch-all", Bench::Payloads::KITTY, 0, CATCH_ALL),
    Scenario.new("csi redraw, full rules", Bench::Payloads::CSI, 0, FULL_RULES),
    Scenario.new("csi redraw, catch-all", Bench::Payloads::CSI, 0, CATCH_ALL),
    Scenario.new("sgr runs, full rules", Bench::Payloads::SGR, 0, FULL_RULES),
    Scenario.new("sgr subparams, catch-all", Bench::Payloads::SGR_SUB, 0, CATCH_ALL),
    Scenario.new("mixed, full rules", Bench::Payloads::MIXED, 0, FULL_RULES),
    Scenario.new("mixed, 4 KiB chunks", Bench::Payloads::MIXED, 4096, FULL_RULES),
    Scenario.new("strings, full rules", Bench::Payloads::STRINGS, 0, FULL_RULES),
    Scenario.new("paste, one byte rule", Bench::Payloads::PASTE, 0, BYTE_RULE),
    Scenario.new("paste, paste tokens", Bench::Payloads::PASTE, 0, PASTE_RULES),
    Scenario.new("paste tokens, 4 KiB chunks", Bench::Payloads::PASTE, 4096, PASTE_RULES),
  ]

  def self.build(s : Scenario) : Bench::Case
    filter = Filter.new
    s.setup.call(filter)

    payload = s.payload
    chunk   = s.chunk == 0 ? payload.size : s.chunk
    units   = (payload.size + chunk - 1) // chunk

    Bench::Case.new(s.name, units, payload.size, -> do
      pos = 0
      while pos < payload.size
        n = Math.min(chunk, payload.size - pos)
        Bench.sink(filter.feed(payload[pos, n]).size)
        pos += n
      end
      nil
    end)
  end

  def self.idle_tick : Bench::Case
    filter = Filter.new
    Bench::Case.new("tick, empty carry", 1, 0, -> do
      Bench.sink(filter.tick.size)
      nil
    end)
  end

  def self.escape_tick : Bench::Case
    filter = Filter.new(2)
    esc    = "\e".to_slice
    Bench::Case.new("tick, lone escape release", 1, 1, -> do
      Bench.sink(filter.feed(esc).size)
      Bench.sink(filter.tick.size)
      Bench.sink(filter.tick.size)
      nil
    end)
  end

  def self.run : Nil
    cases = SCENARIOS.map { |s| build(s) }
    cases << idle_tick
    cases << escape_tick
    Bench.group("input filter", cases)
  end
end

InputFilterBench.run
