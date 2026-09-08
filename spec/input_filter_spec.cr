# spec/input_filter_spec.cr
require "./spec_helper"

describe Term::Mux::InputFilter do
  describe "pass through" do
    it "returns plain input untouched" do
      filter = Term::Mux::InputFilter.new
      filtered(filter, "hello").should eq("hello")
    end

    it "returns empty output for empty input" do
      filter = Term::Mux::InputFilter.new
      filtered(filter, "").should eq("")
    end

    it "forwards unmatched sequences" do
      filter = Term::Mux::InputFilter.new
      filtered(filter, "a\e[Ab\e[?1049hc").should eq("a\e[Ab\e[?1049hc")
    end

    it "forwards sequences with no registered rule for the final byte" do
      filter = Term::Mux::InputFilter.new
      filter.on_csi('h', marker: '?', params: [1004]) { Term::Mux::Disposition.drop }
      filtered(filter, "\e[Z").should eq("\e[Z")
    end
  end

  describe "intercept without consuming" do
    it "observes a mode set and still forwards it" do
      state  = false
      calls  = 0
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) do |token|
        calls += 1
        state = token.set?
        Term::Mux::Disposition.pass
      end

      filtered(filter, "\e[?1004h").should eq("\e[?1004h")
      state.should be_true
      calls.should eq(1)

      filtered(filter, "\e[?1004l").should eq("\e[?1004l")
      state.should be_false
      calls.should eq(2)
    end

    it "keeps surrounding bytes intact" do
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) { Term::Mux::Disposition.pass }
      filtered(filter, "ab\e[?1004hcd").should eq("ab\e[?1004hcd")
    end
  end

  describe "dropping" do
    it "removes an intercepted byte" do
      fired  = 0
      filter = Term::Mux::InputFilter.new
      filter.on_byte(0x02_u8) do
        fired += 1
        Term::Mux::Disposition.drop
      end

      filtered(filter, "a\x02b").should eq("ab")
      fired.should eq(1)
    end

    it "removes an intercepted sequence" do
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) { Term::Mux::Disposition.drop }
      filtered(filter, "x\e[?1004hy").should eq("xy")
    end

    it "removes every occurrence in a run" do
      filter = Term::Mux::InputFilter.new
      filter.on_byte('q') { Term::Mux::Disposition.drop }
      filtered(filter, "qaqqbq").should eq("ab")
    end
  end

  describe "replacing" do
    it "substitutes bytes for a sequence" do
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::CUP) { Term::Mux::Disposition.replace("\e[1;1H") }
      filtered(filter, "\e[9;9H").should eq("\e[1;1H")
    end

    it "substitutes bytes for a literal" do
      filter = Term::Mux::InputFilter.new
      filter.on_byte('a') { Term::Mux::Disposition.replace("A".to_slice) }
      filtered(filter, "cab").should eq("cAb")
    end
  end

  describe "rule matching" do
    it "requires the marker to match" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_csi('h', marker: '?', params: [1004]) do
        fired = true
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\e[1004h").should eq("\e[1004h")
      fired.should be_false
    end

    it "requires the params to match" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) do
        fired = true
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\e[?1049h").should eq("\e[?1049h")
      fired.should be_false
    end

    it "matches any params when the rule declares none" do
      seen   = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::MOUSE_SGR) do |token|
        seen << token.param(0)
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[<0;1;1M\e[<32;5;6M").should eq("\e[<0;1;1M\e[<32;5;6M")
      seen.should eq([0, 32])
    end

    it "matches a params prefix" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_csi('M', marker: '<', params: [0]) do
        fired = true
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[<0;7;8M")
      fired.should be_true
    end

    it "takes the first matching rule" do
      order  = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u', marker: '=') { order << 1; Term::Mux::Disposition.pass }
      filter.on_csi('u', marker: '=') { order << 2; Term::Mux::Disposition.pass }
      filtered(filter, "\e[=31u")
      order.should eq([1])
    end

    it "defaults missing params" do
      value  = -1
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::CUP) do |token|
        value = token.param(1, 1)
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[5H")
      value.should eq(1)
    end

    it "ignores subparameters when parsing" do
      params = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::MOUSE_SGR) do |token|
        params = [token.param(0), token.param(1), token.param(2)]
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[<0:1;12;34M").should eq("\e[<0:1;12;34M")
      params.should eq([0, 12, 34])
    end
  end

  describe "sequence kinds" do
    it "dispatches ss3 sequences" do
      final  = 0_u8
      filter = Term::Mux::InputFilter.new
      filter.on_ss3('P') do |token|
        final = token.final
        Term::Mux::Disposition.drop
      end
      filtered(filter, "a\eOPb").should eq("ab")
      final.should eq('P'.ord.to_u8)
    end

    it "dispatches two-byte escapes" do
      filter = Term::Mux::InputFilter.new
      filter.on_esc('b') { Term::Mux::Disposition.drop }
      filtered(filter, "x\ebz").should eq("xz")
    end

    it "dispatches string sequences terminated by BEL" do
      body   = ""
      filter = Term::Mux::InputFilter.new
      filter.on_string(']') do |token|
        body = String.new(token.bytes)
        Term::Mux::Disposition.drop
      end
      filtered(filter, "a\e]0;title\ab").should eq("ab")
      body.should eq("\e]0;title\a")
    end

    it "dispatches string sequences terminated by ST" do
      body   = ""
      filter = Term::Mux::InputFilter.new
      filter.on_string(']') do |token|
        body = String.new(token.bytes)
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e]0;t\e\\").should eq("\e]0;t\e\\")
      body.should eq("\e]0;t\e\\")
    end

    it "reports the token kind" do
      kinds  = [] of Term::Mux::Token::Kind
      filter = Term::Mux::InputFilter.new
      filter.on_byte('a') { |t| kinds << t.kind; Term::Mux::Disposition.pass }
      filter.on(Term::Mux::Sequences::CUP) { |t| kinds << t.kind; Term::Mux::Disposition.pass }
      filter.on_ss3('P') { |t| kinds << t.kind; Term::Mux::Disposition.pass }
      filtered(filter, "a\e[2;2H\eOP")
      kinds.should eq([
        Term::Mux::Token::Kind::Literal,
        Term::Mux::Token::Kind::Csi,
        Term::Mux::Token::Kind::Ss3,
      ])
    end
  end

  describe "chunk boundaries" do
    it "holds an incomplete sequence until it completes" do
      fired  = 0
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) do
        fired += 1
        Term::Mux::Disposition.pass
      end

      filtered(filter, "\e[?10").should eq("")
      fired.should eq(0)
      filtered(filter, "04h").should eq("\e[?1004h")
      fired.should eq(1)
    end

    it "splits a sequence across three chunks" do
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::MOUSE_SGR) { Term::Mux::Disposition.drop }
      filtered(filter, "\e[<0").should eq("")
      filtered(filter, ";12").should eq("")
      filtered(filter, ";34Mtail").should eq("tail")
    end

    it "emits literals before an incomplete sequence" do
      filter = Term::Mux::InputFilter.new
      filtered(filter, "abc\e[").should eq("abc")
      filtered(filter, "2J").should eq("\e[2J")
    end

    it "holds an incomplete string sequence" do
      filter = Term::Mux::InputFilter.new
      filter.on_string(']') { Term::Mux::Disposition.drop }
      filtered(filter, "\e]0;par").should eq("")
      filtered(filter, "tial\a").should eq("")
    end

    it "flushes an oversized carry verbatim" do
      filter = Term::Mux::InputFilter.new
      input  = "\e[" + ("1;" * 5000)
      filtered(filter, input).should eq(input)
      filtered(filter, "x").should eq("x")
    end
  end

  describe "lone escape" do
    it "withholds a trailing escape from the chunk" do
      filter = Term::Mux::InputFilter.new
      filtered(filter, "a\e").should eq("a")
    end

    it "releases it after the configured ticks" do
      filter = Term::Mux::InputFilter.new
      filtered(filter, "\e").should eq("")
      ticked(filter).should eq("")
      ticked(filter).should eq("\e")
      ticked(filter).should eq("")
    end

    it "releases it after one tick when configured" do
      filter = Term::Mux::InputFilter.new(1)
      filtered(filter, "\e").should eq("")
      ticked(filter).should eq("\e")
    end

    it "applies byte rules to the released escape" do
      fired  = false
      filter = Term::Mux::InputFilter.new(1)
      filter.on_byte(0x1B_u8) do
        fired = true
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\e").should eq("")
      ticked(filter).should eq("")
      fired.should be_true
    end

    it "resets the tick count when more input arrives" do
      filter = Term::Mux::InputFilter.new
      filtered(filter, "\e").should eq("")
      ticked(filter).should eq("")
      filtered(filter, "[2J").should eq("\e[2J")
      ticked(filter).should eq("")
    end

    it "returns nothing from tick when the carry is empty" do
      filter = Term::Mux::InputFilter.new
      ticked(filter).should eq("")
    end
  end

  describe "bracketed paste" do
    it "tracks the paste state" do
      filter = Term::Mux::InputFilter.new
      filter.paste?.should be_false
      filtered(filter, "\e[200~")
      filter.paste?.should be_true
      filtered(filter, "\e[201~")
      filter.paste?.should be_false
    end

    it "forwards the paste markers" do
      filter = Term::Mux::InputFilter.new
      filtered(filter, "\e[200~text\e[201~").should eq("\e[200~text\e[201~")
    end

    it "suppresses byte rules inside a paste" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_byte(0x02_u8) do
        fired = true
        Term::Mux::Disposition.drop
      end

      filtered(filter, "\e[200~a\x02b\e[201~").should eq("\e[200~a\x02b\e[201~")
      fired.should be_false
      filtered(filter, "\x02").should eq("")
      fired.should be_true
    end

    it "suppresses sequence rules inside a paste" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) do
        fired = true
        Term::Mux::Disposition.drop
      end

      filtered(filter, "\e[200~\e[?1004h\e[201~").should eq("\e[200~\e[?1004h\e[201~")
      fired.should be_false
    end

    it "spans chunk boundaries" do
      filter = Term::Mux::InputFilter.new
      filter.on_byte(0x02_u8) { Term::Mux::Disposition.drop }
      filtered(filter, "\e[200~").should eq("\e[200~")
      filtered(filter, "\x02").should eq("\x02")
      filtered(filter, "\e[201~").should eq("\e[201~")
      filtered(filter, "\x02").should eq("")
    end
  end

  describe "pass_next" do
    it "forwards the next byte untouched" do
      fired = 0
      filter = uninitialized Term::Mux::InputFilter
      filter = Term::Mux::InputFilter.new
      filter.on_byte(0x02_u8) do
        fired += 1
        filter.pass_next!
        Term::Mux::Disposition.drop
      end

      filtered(filter, "\x02\x02b").should eq("\x02b")
      fired.should eq(1)
    end

    it "forwards the next sequence untouched" do
      fired  = 0
      filter = Term::Mux::InputFilter.new
      filter.on_byte(0x02_u8) do
        filter.pass_next!
        Term::Mux::Disposition.drop
      end
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) do
        fired += 1
        Term::Mux::Disposition.drop
      end

      filtered(filter, "\x02\e[?1004h").should eq("\e[?1004h")
      fired.should eq(0)
      filtered(filter, "\e[?1004h").should eq("")
      fired.should eq(1)
    end

    it "spans chunk boundaries" do
      filter = Term::Mux::InputFilter.new
      filter.on_byte(0x02_u8) do
        filter.pass_next!
        Term::Mux::Disposition.drop
      end

      filtered(filter, "\x02").should eq("")
      filtered(filter, "\x02x").should eq("\x02x")
    end
  end

  describe "mode pairs" do
    it "registers both directions from one call" do
      seen   = [] of Bool
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::IN_BAND_RESIZE) do |token|
        seen << token.set?
        Term::Mux::Disposition.pass
      end

      filtered(filter, "\e[?2048h\e[?2048l").should eq("\e[?2048h\e[?2048l")
      seen.should eq([true, false])
    end
  end
end
