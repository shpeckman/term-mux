# spec/server_spec.cr
require "./spec_helper"

class SpecDelegate < Term::Mux::ServerDelegate
  getter attaches = [] of Term::Mux::Protocol::AttachInfo
  getter inputs = [] of String
  getter resizes = [] of Tuple(Int32, Int32)
  getter commands = [] of Array(String)
  getter detaches = 0
  getter ticks = 0

  property server : Term::Mux::Server?
  property render_on_attach : String?

  def on_attach(client : Term::Mux::ClientConn, info : Term::Mux::Protocol::AttachInfo) : Nil
    @attaches << info
    if text = @render_on_attach
      @server.try &.send_render(client, text.to_slice)
    end
  end

  def on_resize(client : Term::Mux::ClientConn, cols : Int32, rows : Int32) : Nil
    @resizes << {cols, rows}
  end

  def on_input(client : Term::Mux::ClientConn, payload : Bytes) : Nil
    @inputs << String.new(payload)
  end

  def on_command(client : Term::Mux::ClientConn, argv : Array(String)) : {Bool, String}
    @commands << argv
    return {false, "unknown"} if argv.empty?
    {argv[0] == "ok", argv.join(" ")}
  end

  def on_detach(client : Term::Mux::ClientConn) : Nil
    @detaches += 1
  end

  def on_tick : Nil
    @ticks += 1
  end
end

def with_server(delegate : SpecDelegate, &)
  path   = spec_socket_path
  server = Term::Mux::Server.new(path, delegate)
  delegate.server = server
  spawn { server.run }
  wait_until { File.exists?(path) }.should be_true
  begin
    yield server, path
  ensure
    File.delete(path) if File.exists?(path)
  end
end

describe Term::Mux::Server, tags: "integration" do
  it "answers commands with a reply frame" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      client = Term::Mux::Client.new(path)
      ok, text = client.send_command(["ok", "there"])
      ok.should be_true
      text.should eq("ok there")
      delegate.commands.should eq([["ok", "there"]])
    end
  end

  it "reports command failure" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      ok, text = Term::Mux::Client.new(path).send_command(["nope"])
      ok.should be_false
      text.should eq("nope")
    end
  end

  it "delivers attach info to the delegate" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      sock = UNIXSocket.new(path)
      info = Term::Mux::Protocol::AttachInfo.new(100, 30, 0, 0, true, "main", "", "/tmp")
      Term::Mux::Protocol.write(sock, Term::Mux::Protocol::Kind::Attach, info.encode)

      wait_until { delegate.attaches.size == 1 }.should be_true
      delegate.attaches[0].cols.should eq(100)
      delegate.attaches[0].session_name.should eq("main")
      sock.close
    end
  end

  it "sends render frames to the attached client" do
    delegate = SpecDelegate.new
    delegate.render_on_attach = "\e[2Jhello"
    with_server(delegate) do |server, path|
      sock = UNIXSocket.new(path)
      info = Term::Mux::Protocol::AttachInfo.new(80, 24, 0, 0, true, "s", "", "")
      Term::Mux::Protocol.write(sock, Term::Mux::Protocol::Kind::Attach, info.encode)

      kind, payload = Term::Mux::Protocol.read(sock).not_nil!
      kind.render?.should be_true
      String.new(payload).should eq("\e[2Jhello")
      sock.close
    end
  end

  it "forwards input and resize frames" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      sock = UNIXSocket.new(path)
      Term::Mux::Protocol.write(sock, Term::Mux::Protocol::Kind::Input, "abc".to_slice)
      Term::Mux::Protocol.write(sock, Term::Mux::Protocol::Kind::Resize, Term::Mux::Protocol.encode_xy(90, 20))

      wait_until { delegate.inputs.size == 1 && delegate.resizes.size == 1 }.should be_true
      delegate.inputs.should eq(["abc"])
      delegate.resizes.should eq([{90, 20}])
      sock.close
    end
  end

  it "tracks connected clients" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      sock = UNIXSocket.new(path)
      Term::Mux::Protocol.write(sock, Term::Mux::Protocol::Kind::Input, "x".to_slice)
      wait_until { server.clients.size == 1 }.should be_true

      sock.close
      wait_until { server.clients.empty? }.should be_true
      delegate.detaches.should eq(1)
    end
  end

  it "detaches on request" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      sock = UNIXSocket.new(path)
      Term::Mux::Protocol.write(sock, Term::Mux::Protocol::Kind::Detach)
      wait_until { delegate.detaches == 1 }.should be_true
      sock.close
    end
  end

  it "stops writing to a client after exit" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      sock = UNIXSocket.new(path)
      Term::Mux::Protocol.write(sock, Term::Mux::Protocol::Kind::Input, "x".to_slice)
      wait_until { server.clients.size == 1 }.should be_true

      conn = server.clients[0]
      server.send_exit(conn, 3)
      conn.alive.should be_false

      kind, payload = Term::Mux::Protocol.read(sock).not_nil!
      kind.exit?.should be_true
      payload[0].should eq(3_u8)
      sock.close
    end
  end

  it "runs the tick loop" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      wait_until { delegate.ticks > 2 }.should be_true
    end
  end

  it "serves several clients at once" do
    delegate = SpecDelegate.new
    with_server(delegate) do |server, path|
      a = UNIXSocket.new(path)
      b = UNIXSocket.new(path)
      Term::Mux::Protocol.write(a, Term::Mux::Protocol::Kind::Input, "a".to_slice)
      Term::Mux::Protocol.write(b, Term::Mux::Protocol::Kind::Input, "b".to_slice)

      wait_until { delegate.inputs.size == 2 }.should be_true
      delegate.inputs.sort.should eq(["a", "b"])
      server.clients.size.should eq(2)

      a.close
      b.close
    end
  end
end

describe Term::Mux::Client, tags: "integration" do
  it "fails cleanly with no server and no daemon" do
    ok, text = Term::Mux::Client.new(spec_socket_path).send_command(["ls"])
    ok.should be_false
    text.should eq("no server running")
  end
end
