# bench/output_filter_bench.cr
require "./bench_helper"

module OutputFilterBench
  alias Filter = Term::Mux::OutputFilter
  alias Disp = Term::Mux::Disposition

  record Scenario, name : String, payload : Bytes, chunk : Int32, setup : Proc(Filter, Nil)

  NO_RULES = ->(f : Filter) { nil }

  BYTE_RULE = ->(f : Filter) do
    f.on_byte(0x07_u8) { Disp.drop }
    nil
  end

  FULL_RULES = ->(f : Filter) do
    f.on_byte(0x07_u8) { Disp.drop }
    f.on(Term::Mux::Sequences::ALT_SCREEN) { Disp.pass }
    f.on(Term::Mux::Sequences::SYNCHRONIZED) { Disp.pass }
    f.on(Term::Mux::Sequences::CURSOR_VISIBLE) { Disp.pass }
    f.on(Term::Mux::Sequences::CUP) { Disp.pass }
    f.on_ss3('A') { Disp.pass }
    f.on_esc('c') { Disp.drop }
    f.on_osc(0) { Disp.pass }
    f.on_osc { Disp.drop }
    f.on_dcs('q') { Disp.pass }
    f.on_apc { Disp.drop }
    nil
  end

  SCENARIOS = [
    Scenario.new("plain text, no rules", Bench::Payloads::PLAIN, 0, NO_RULES),
    Scenario.new("plain text, one byte rule", Bench::Payloads::PLAIN, 0, BYTE_RULE),
    Scenario.new("csi redraw, no rules", Bench::Payloads::CSI, 0, NO_RULES),
    Scenario.new("csi redraw, full rules", Bench::Payloads::CSI, 0, FULL_RULES),
    Scenario.new("sgr runs, full rules", Bench::Payloads::SGR, 0, FULL_RULES),
    Scenario.new("mixed, full rules", Bench::Payloads::MIXED, 0, FULL_RULES),
    Scenario.new("mixed, 16 KiB chunks", Bench::Payloads::MIXED, 16384, FULL_RULES),
    Scenario.new("mixed, 4 KiB chunks", Bench::Payloads::MIXED, 4096, FULL_RULES),
    Scenario.new("mixed, 256 B chunks", Bench::Payloads::MIXED, 256, FULL_RULES),
    Scenario.new("strings, full rules", Bench::Payloads::STRINGS, 0, FULL_RULES),
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

  def self.run : Nil
    Bench.group("output filter", SCENARIOS.map { |s| build(s) })
  end
end

OutputFilterBench.run
