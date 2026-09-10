# examples/middleman_demo.cr
require "../src/term-mux"

alias Mux = Term::Mux
alias Seq = Term::Seq

Seq::Emitter.define do
  csi sgr_bold, final: 'm', params: {1}
  csi sgr_reset, final: 'm', params: {0}
  osc title(text), code: 0
end

def emitted(& : Seq::Emitter ->) : Bytes
  em = Seq::Emitter.new
  yield em
  em.take
end

mid = Mux::Middleman.new(
  setup: emitted { |e| e.title("term-mux middleman") },
  teardown: emitted { |e| e.title("terminal") })

mid.output.on_byte(0x07_u8) { |t| Seq::Disposition.drop }
mid.output.on_osc(52) { |t| Seq::Disposition.drop }

mid.input.on_byte(0x02_u8) do |t|
  mid.inject_host { |e| e.sgr_bold.text("\r\n[middleman] hello from the host side\r\n").sgr_reset }
  Seq::Disposition.drop
end

mid.input.on_byte(0x14_u8) do |t|
  mid.inject_child { |e| e.text("date '+it is %T'\n") }
  Seq::Disposition.drop
end

spawn do
  sleep 200.milliseconds
  mid.inject_host { |e| e.text("[term-mux] attached (ctrl-t: run date, ctrl-b: host banner)\r\n") }
  mid.inject_child { |e| e.text("echo the middleman injected this\n") }
end

exit mid.run
