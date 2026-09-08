# src/mux/server.cr
module Term::Mux
  class ClientConn
    getter id      : String
    getter io      : UNIXSocket
    property alive : Bool = true

    def initialize(@id : String, @io : UNIXSocket)
    end

    def send(kind : Protocol::Kind, payload : Bytes = Bytes.empty) : Nil
      Protocol.write(@io, kind, payload) rescue nil
    end
  end

  abstract class ServerDelegate
    abstract def on_attach(client : ClientConn, info : Protocol::AttachInfo) : Nil
    abstract def on_resize(client : ClientConn, cols : Int32, rows : Int32) : Nil
    abstract def on_input(client : ClientConn, payload : Bytes) : Nil
    abstract def on_command(client : ClientConn, argv : Array(String)) : {Bool, String}
    abstract def on_detach(client : ClientConn) : Nil
    abstract def on_tick : Nil
  end

  class Server
    getter clients : Array(ClientConn)

    @socket_path : String
    @socket      : UNIXServer?
    @delegate    : ServerDelegate
    @running     : Bool  = true
    @next_id     : Int32 = 0

    def initialize(@socket_path : String, @delegate : ServerDelegate)
      @clients = [] of ClientConn
    end

    def run : Nil
      FileUtils.mkdir_p(File.dirname(@socket_path))
      File.delete(@socket_path) if File.exists?(@socket_path)
      server  = UNIXServer.new(@socket_path)
      @socket = server

      Signal::TERM.trap { stop(0) }
      Signal::INT.trap { stop(0) }

      spawn accept_loop(server)
      spawn tick_loop

      while @running
        sleep 1.second
      end
    end

    def stop(code : Int32) : Nil
      @running = false
      @clients.each do |c|
        c.send(Protocol::Kind::Exit, Bytes[0])
        c.io.close rescue nil
      end
      @socket.try &.close rescue nil
      File.delete(@socket_path) if File.exists?(@socket_path)
      exit(code)
    end

    def send_render(client : ClientConn, bytes : Bytes) : Nil
      client.send(Protocol::Kind::Render, bytes)
    end

    def send_bell(client : ClientConn) : Nil
      client.send(Protocol::Kind::Bell)
    end

    def send_exit(client : ClientConn, code : Int32 = 0) : Nil
      client.send(Protocol::Kind::Exit, Bytes[code.to_u8])
      client.alive = false
    end

    private def accept_loop(server : UNIXServer) : Nil
      loop do
        sock = server.accept
        id   = @next_id.to_s
        @next_id += 1
        conn = ClientConn.new(id, sock)
        @clients << conn
        spawn handle_client(conn)
      end
    rescue
    end

    private def tick_loop : Nil
      while @running
        sleep 8.milliseconds
        @delegate.on_tick
      end
    end

    private def handle_client(conn : ClientConn) : Nil
      loop do
        msg = Protocol.read(conn.io)
        break unless msg
        kind, payload = msg
        case kind
        when .attach?
          info = Protocol::AttachInfo.decode(payload)
          @delegate.on_attach(conn, info)
        when .input?
          @delegate.on_input(conn, payload)
        when .resize?
          cols, rows = Protocol.decode_xy(payload)
          @delegate.on_resize(conn, cols, rows)
        when .detach?
          break
        when .command?
          argv = Protocol.decode_argv(payload)
          ok, text = @delegate.on_command(conn, argv)
          reply = IO::Memory.new
          reply.write_byte(ok ? 1_u8 : 0_u8)
          Protocol.write_str(reply, text)
          conn.send(Protocol::Kind::Reply, reply.to_slice)
        else
        end
        break unless conn.alive
      end
    rescue IO::Error
    ensure
      conn.alive = false
      @clients.delete(conn)
      @delegate.on_detach(conn)
      conn.io.close rescue nil
    end
  end
end
