# spec/pty_spec.cr
require "./spec_helper"

private def shutdown(host : Term::Mux::PtyHost) : Nil
  wait_until(2.seconds) { host.dead }
  host.close
  host.pty.wait
  Fiber.yield
end

private def run_host(cols : Int32, rows : Int32, command : String, cwd : String, &) : String
  output = IO::Memory.new
  dead   = false

  host = Term::Mux::PtyHost.new(cols, rows, command, cwd,
    on_output: ->(bytes : Bytes) { output.write(bytes) },
    on_dead: -> { dead = true; nil })

  yield host
  wait_until(5.seconds) { dead }.should be_true
  shutdown(host)
  output.to_s
end

describe Term::Mux::PtyHost, tags: "integration" do
  it "runs a command and reports its output" do
    run_host(80, 24, "printf term-mux-ok", Dir.current) { }.should contain("term-mux-ok")
  end

  it "exposes the child pid" do
    pid = 0_i64
    run_host(80, 24, "exit 0", Dir.current) { |host| pid = host.pid }
    pid.should be > 0
  end

  it "runs the command in the given directory" do
    run_host(80, 24, "pwd", Dir.tempdir) { }.should contain(File.realpath(Dir.tempdir))
  end

  it "reports the terminal size to the child" do
    run_host(97, 31, "stty size", Dir.current) { }.should contain("31 97")
  end

  it "runs the child in its own session" do
    out       = run_host(80, 24, "ps -o sid= -p $$", Dir.current) { }
    child_sid = out.strip.to_i
    child_sid.should_not eq(`ps -o sid= -p #{Process.pid}`.strip.to_i)
  end

  it "gives the child a controlling terminal" do
    run_host(80, 24, "tty", Dir.current) { }.should contain("/dev/pts/")
  end

  it "writes input to the child" do
    out = run_host(80, 24, "read line; printf 'got:%s' \"$line\"", Dir.current) do |host|
      sleep 100.milliseconds
      host.write("ping\n")
    end
    out.should contain("got:ping")
  end

  it "ignores degenerate resizes" do
    run_host(80, 24, "sleep 0.2", Dir.current) do |host|
      host.resize(0, 0)
      host.resize(100, 40)
    end
  end

  it "reports liveness" do
    alive = false
    run_host(80, 24, "sleep 0.2", Dir.current) { |host| alive = host.pty.alive? }
    alive.should be_true
  end

  it "reports the foreground command" do
    name = ""
    run_host(80, 24, "sleep 0.3", Dir.current) do |host|
      sleep 100.milliseconds
      name = host.current_command
    end
    name.should eq("sleep")
  end

  it "reaps the child rather than leaving a zombie" do
    host   = Term::Mux::PtyHost.new(80, 24, "exit 7", Dir.current)
    status = host.pty.wait
    status.exit_code.should eq(7)
    host.close
  end
end
