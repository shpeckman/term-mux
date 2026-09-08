# spec/protocol_spec.cr
require "./spec_helper"

describe Term::Mux::Protocol do
  it "round-trips a framed message" do
    io = IO::Memory.new
    Term::Mux::Protocol.write(io, Term::Mux::Protocol::Kind::Input, "abc".to_slice)
    io.rewind

    kind, payload = Term::Mux::Protocol.read(io).not_nil!
    kind.input?.should be_true
    String.new(payload).should eq("abc")
  end

  it "round-trips an empty payload" do
    io = IO::Memory.new
    Term::Mux::Protocol.write(io, Term::Mux::Protocol::Kind::Bell)
    io.rewind

    kind, payload = Term::Mux::Protocol.read(io).not_nil!
    kind.bell?.should be_true
    payload.empty?.should be_true
  end

  it "reads messages in order" do
    io = IO::Memory.new
    Term::Mux::Protocol.write(io, Term::Mux::Protocol::Kind::Render, "one".to_slice)
    Term::Mux::Protocol.write(io, Term::Mux::Protocol::Kind::Render, "two".to_slice)
    io.rewind

    String.new(Term::Mux::Protocol.read(io).not_nil![1]).should eq("one")
    String.new(Term::Mux::Protocol.read(io).not_nil![1]).should eq("two")
    Term::Mux::Protocol.read(io).should be_nil
  end

  it "returns nil at end of stream" do
    Term::Mux::Protocol.read(IO::Memory.new).should be_nil
  end

  it "returns nil on a truncated payload" do
    io = IO::Memory.new
    io.write_byte(Term::Mux::Protocol::Kind::Input.value)
    io.write_bytes(16_u32, Term::Mux::Protocol::LE)
    io.write("abc".to_slice)
    io.rewind

    Term::Mux::Protocol.read(io).should be_nil
  end

  it "rejects an oversized frame" do
    io = IO::Memory.new
    io.write_byte(Term::Mux::Protocol::Kind::Input.value)
    io.write_bytes(Term::Mux::Protocol::MAX_PAYLOAD + 1, Term::Mux::Protocol::LE)
    io.rewind

    Term::Mux::Protocol.read(io).should be_nil
  end

  it "round-trips strings" do
    io = IO::Memory.new
    Term::Mux::Protocol.write_str(io, "héllo")
    Term::Mux::Protocol.write_str(io, "")
    io.rewind

    Term::Mux::Protocol.read_str(io).should eq("héllo")
    Term::Mux::Protocol.read_str(io).should eq("")
  end

  it "round-trips argv" do
    argv = ["new", "-s", "main session"]
    Term::Mux::Protocol.decode_argv(Term::Mux::Protocol.encode_argv(argv)).should eq(argv)
  end

  it "round-trips an empty argv" do
    Term::Mux::Protocol.decode_argv(Term::Mux::Protocol.encode_argv([] of String)).should be_empty
  end

  it "round-trips coordinates" do
    Term::Mux::Protocol.decode_xy(Term::Mux::Protocol.encode_xy(120, 40)).should eq({120, 40})
  end

  describe Term::Mux::Protocol::AttachInfo do
    it "round-trips every field" do
      info = Term::Mux::Protocol::AttachInfo.new(
        cols: 120, rows: 40, xpixel: 1440, ypixel: 800,
        new_session: true, session_name: "main", command: "htop", cwd: "/tmp")

      decoded = Term::Mux::Protocol::AttachInfo.decode(info.encode)
      decoded.cols.should eq(120)
      decoded.rows.should eq(40)
      decoded.xpixel.should eq(1440)
      decoded.ypixel.should eq(800)
      decoded.new_session.should be_true
      decoded.session_name.should eq("main")
      decoded.command.should eq("htop")
      decoded.cwd.should eq("/tmp")
    end

    it "round-trips empty strings and a false flag" do
      info = Term::Mux::Protocol::AttachInfo.new(
        cols: 80, rows: 24, xpixel: 0, ypixel: 0,
        new_session: false, session_name: "", command: "", cwd: "")

      decoded = Term::Mux::Protocol::AttachInfo.decode(info.encode)
      decoded.new_session.should be_false
      decoded.session_name.should eq("")
      decoded.command.should eq("")
      decoded.cwd.should eq("")
    end
  end
end
