# spec/middleman_spec.cr
require "./spec_helper"

private def run_mid(command : String, host_in : IO = IO::Memory.new, & : Term::Mux::Middleman -> Nil) : {Int32, String}
  host_out = IO::Memory.new
  mid      = Term::Mux::Middleman.new(command, Dir.current, host_in: host_in, host_out: host_out)
  yield mid
  code = mid.run
  {code, host_out.to_s}
end

private def run_mid_async(command : String, host_out : IO::Memory, & : Term::Mux::Middleman -> Nil) : Int32
  mid  = Term::Mux::Middleman.new(command, Dir.current, host_out: host_out)
  done = Channel(Int32).new(1)
  spawn { done.send(mid.run) }
  sleep 100.milliseconds
  yield mid
  done.receive
end

describe Term::Mux::Middleman, tags: "integration" do
  it "passes child output through to the host" do
    _, out = run_mid("printf mid-ok") { }
    out.should contain("mid-ok")
  end

  it "returns the child exit code" do
    code, _ = run_mid("exit 3") { }
    code.should eq(3)
  end

  it "writes setup and teardown bytes around the session" do
    host_out = IO::Memory.new
    Term::Mux::Middleman.new("printf body", Dir.current,
      setup: "S".to_slice, teardown: "T".to_slice, host_out: host_out).run
    host_out.to_s.should eq("SbodyT")
  end

  it "applies output filter rules to child output" do
    _, out = run_mid("printf abc") do |mid|
      mid.output.on_byte('b') { |t| Term::Mux::Disposition.replace("B") }
    end
    out.should contain("aBc")
  end

  it "drops filtered child output" do
    _, out = run_mid("printf abc") do |mid|
      mid.output.on_byte('b') { |t| Term::Mux::Disposition.drop }
    end
    out.should contain("ac")
    out.should_not contain("abc")
  end

  it "feeds host input through to the child" do
    _, out = run_mid("read line; printf 'got:%s' \"$line\"", IO::Memory.new("ping\n")) { }
    out.should contain("got:ping")
  end

  it "applies input filter rules to host input" do
    _, out = run_mid("read line; printf 'got:%s' \"$line\"", IO::Memory.new("ping\n")) do |mid|
      mid.input.on_byte('p') { |t| Term::Mux::Disposition.replace("P") }
    end
    out.should contain("got:Ping")
  end

  it "injects emitter bytes into the child" do
    host_out = IO::Memory.new
    code = run_mid_async("read line; printf 'got:%s' \"$line\"", host_out) do |mid|
      mid.inject_child { |e| e.text("injected\n") }
    end
    code.should eq(0)
    host_out.to_s.should contain("got:injected")
  end

  it "injects emitter bytes to the host" do
    host_out = IO::Memory.new
    run_mid_async("sleep 0.2", host_out) do |mid|
      mid.inject_host { |e| e.text("host-injected") }
    end
    host_out.to_s.should contain("host-injected")
  end

  it "releases a lone escape to the child through the tick loop" do
    host_out = IO::Memory.new
    rin, win = IO.pipe
    mid = Term::Mux::Middleman.new("read line; printf %s \"$line\" | od -An -tx1", Dir.current,
      host_in: rin, host_out: host_out)
    done = Channel(Int32).new(1)
    spawn { done.send(mid.run) }
    sleep 100.milliseconds
    win.write("\e".to_slice)
    sleep 100.milliseconds
    win.write("\n".to_slice)
    done.receive
    host_out.to_s.should contain("1b")
  end
end
