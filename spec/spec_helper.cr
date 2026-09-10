# spec/spec_helper.cr
require "spec"
require "../src/term-mux"

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
