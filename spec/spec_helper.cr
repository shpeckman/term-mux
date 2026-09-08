# spec/spec_helper.cr
require "spec"
require "../src/term-mux"

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
