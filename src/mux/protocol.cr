# src/mux/protocol.cr
module Term::Mux::Protocol
  LE = IO::ByteFormat::LittleEndian

  enum Kind : UInt8
    Attach
    Input
    Resize
    Detach
    Command
    Render
    Exit
    Reply
    Bell
  end

  MAX_PAYLOAD = 64_u32 * 1024 * 1024

  def self.write(io : IO, kind : Kind, payload : Bytes = Bytes.empty) : Nil
    io.write_byte(kind.value)
    io.write_bytes(payload.size.to_u32, LE)
    io.write(payload) unless payload.empty?
    io.flush
  end

  def self.read(io : IO) : {Kind, Bytes}?
    b = io.read_byte
    return nil unless b
    kind = Kind.new(b)
    len  = io.read_bytes(UInt32, LE)
    return nil if len > MAX_PAYLOAD
    payload = Bytes.new(len)
    io.read_fully(payload)
    {kind, payload}
  rescue IO::EOFError
    nil
  end

  def self.write_str(io : IO, s : String) : Nil
    io.write_bytes(s.bytesize.to_u32, LE)
    io << s
  end

  def self.read_str(io : IO) : String
    len = io.read_bytes(UInt32, LE)
    raise IO::EOFError.new if len > MAX_PAYLOAD
    buf = Bytes.new(len)
    io.read_fully(buf)
    String.new(buf)
  end

  record AttachInfo,
    cols         : Int32,
    rows         : Int32,
    xpixel       : Int32,
    ypixel       : Int32,
    new_session  : Bool,
    session_name : String,
    command      : String,
    cwd          : String do
    def encode : Bytes
      io = IO::Memory.new
      io.write_bytes(@cols.to_i32, Protocol::LE)
      io.write_bytes(@rows.to_i32, Protocol::LE)
      io.write_bytes(@xpixel.to_i32, Protocol::LE)
      io.write_bytes(@ypixel.to_i32, Protocol::LE)
      io.write_byte(@new_session ? 1_u8 : 0_u8)
      Protocol.write_str(io, @session_name)
      Protocol.write_str(io, @command)
      Protocol.write_str(io, @cwd)
      io.to_slice
    end

    def self.decode(payload : Bytes) : AttachInfo
      io     = IO::Memory.new(payload)
      cols   = io.read_bytes(Int32, Protocol::LE)
      rows   = io.read_bytes(Int32, Protocol::LE)
      xpixel = io.read_bytes(Int32, Protocol::LE)
      ypixel = io.read_bytes(Int32, Protocol::LE)
      ns     = io.read_byte.not_nil! != 0_u8
      new(cols, rows, xpixel, ypixel, ns, Protocol.read_str(io), Protocol.read_str(io), Protocol.read_str(io))
    end
  end

  def self.encode_argv(argv : Array(String)) : Bytes
    io = IO::Memory.new
    io.write_bytes(argv.size.to_u32, LE)
    argv.each { |a| write_str(io, a) }
    io.to_slice
  end

  def self.decode_argv(payload : Bytes) : Array(String)
    io    = IO::Memory.new(payload)
    count = io.read_bytes(UInt32, LE)
    Array(String).new(count) { read_str(io) }
  end

  def self.encode_xy(x : Int32, y : Int32) : Bytes
    io = IO::Memory.new
    io.write_bytes(x.to_i32, LE)
    io.write_bytes(y.to_i32, LE)
    io.to_slice
  end

  def self.decode_xy(payload : Bytes) : {Int32, Int32}
    io = IO::Memory.new(payload)
    {io.read_bytes(Int32, LE), io.read_bytes(Int32, LE)}
  end
end
