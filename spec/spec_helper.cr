# spec/spec_helper.cr
require "spec"
require "../src/term-mux"

Term::Mux::Emitter.define do
  decset alt_screen, mode: 1049
  decset cursor_visible, mode: 25
  decset bracketed_paste, mode: 2004
  decset focus_events, mode: 1004
  decset in_band_resize, mode: 2048
  decset synchronized, mode: 2026, block: true

  csi kitty_keyboard(flags), marker: '=', final: 'u'
  csi mouse_sgr(button, x, y), marker: '<', final: 'M'
  csi cup(row, col), final: 'H', defaults: {1, 1}
  csi cursor_up(rows), final: 'A', defaults: {1}
  csi cursor_down(rows), final: 'B', defaults: {1}
  csi erase_display(target), final: 'J', defaults: {0}
  csi erase_line(target), final: 'K', defaults: {0}
  csi sgr_reset, final: 'm', params: {0}
  csi home, final: 'H'

  osc title(text), code: 0
end

def rendered(emitter : Term::Mux::Emitter) : String
  String.new(emitter.bytes)
end

def filtered(filter : Term::Mux::InputFilter, input : String) : String
  String.new(filter.feed(input.to_slice))
end

def filtered(filter : Term::Mux::InputFilter, input : Bytes) : String
  String.new(filter.feed(input))
end

def ticked(filter : Term::Mux::InputFilter) : String
  String.new(filter.tick)
end

def output_filtered(filter : Term::Mux::OutputFilter, input : String) : String
  String.new(filter.feed(input.to_slice))
end

def output_filtered(filter : Term::Mux::OutputFilter, input : Bytes) : String
  String.new(filter.feed(input))
end

def wait_until(timeout : Time::Span = 2.seconds, &) : Bool
  deadline = Time.instant + timeout
  while Time.instant < deadline
    return true if yield
    sleep 2.milliseconds
  end
  false
end

def spec_socket_path : String
  File.join(Dir.tempdir, "term-mux-spec-#{Random.rand(UInt64)}.sock")
end
