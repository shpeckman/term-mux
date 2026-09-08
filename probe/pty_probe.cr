# probe/pty_probe.cr
require "../src/term-mux"

lib LibC
  fun getsid(pid : PidT) : PidT
end

Signal::INT.trap { STDERR.puts "  <- SIGINT"; STDERR.flush }
Signal::HUP.trap { STDERR.puts "  <- SIGHUP"; STDERR.flush }
Signal::TERM.trap { STDERR.puts "  <- SIGTERM"; STDERR.flush }
Signal::QUIT.trap { STDERR.puts "  <- SIGQUIT"; STDERR.flush }
Signal::PIPE.trap { STDERR.puts "  <- SIGPIPE"; STDERR.flush }

STDERR.puts "pid #{Process.pid} pgid #{LibC.getpgid(0)} sid #{LibC.getsid(0)}"

host = Term::Mux::PtyHost.new(80, 24, "exit 0", Dir.current)
STDERR.puts "spawned child #{host.pid}"

host.close
STDERR.puts "master closed"

sleep 200.milliseconds
STDERR.puts "still alive after close"

result = LibPty.waitpid(host.pid, out status, 1)
STDERR.puts "waitpid -> #{result} status #{status}"

sleep 200.milliseconds
STDERR.puts "done"
