# spec/output_filter_spec.cr
require "./spec_helper"

describe Term::Mux::OutputFilter do
  describe "pass through" do
    it "returns plain output untouched" do
      filter = Term::Mux::OutputFilter.new
      output_filtered(filter, "hello").should eq("hello")
    end

    it "returns empty output for empty input" do
      filter = Term::Mux::OutputFilter.new
      output_filtered(filter, "").should eq("")
    end

    it "forwards unmatched sequences" do
      filter = Term::Mux::OutputFilter.new
      output_filtered(filter, "a\e[Ab\e[?1049hc").should eq("a\e[Ab\e[?1049hc")
    end

    it "forwards sequences with no registered rule for the final byte" do
      filter = Term::Mux::OutputFilter.new
      filter.on_csi('h', marker: '?', params: [1049]) { Term::Mux::Disposition.drop }
      output_filtered(filter, "\e[Z").should eq("\e[Z")
    end
  end

  describe "intercept without consuming" do
    it "observes a mode set and still forwards it" do
      state  = false
      calls  = 0
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::ALT_SCREEN) do |token|
        calls += 1
        state = token.set?
        Term::Mux::Disposition.pass
      end

      output_filtered(filter, "\e[?1049h").should eq("\e[?1049h")
      state.should be_true
      calls.should eq(1)

      output_filtered(filter, "\e[?1049l").should eq("\e[?1049l")
      state.should be_false
      calls.should eq(2)
    end

    it "keeps surrounding bytes intact" do
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::ALT_SCREEN) { Term::Mux::Disposition.pass }
      output_filtered(filter, "ab\e[?1049hcd").should eq("ab\e[?1049hcd")
    end
  end

  describe "dropping" do
    it "removes an intercepted byte" do
      fired  = 0
      filter = Term::Mux::OutputFilter.new
      filter.on_byte(0x07_u8) do
        fired += 1
        Term::Mux::Disposition.drop
      end

      output_filtered(filter, "a\ab").should eq("ab")
      fired.should eq(1)
    end

    it "removes an intercepted sequence" do
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::ALT_SCREEN) { Term::Mux::Disposition.drop }
      output_filtered(filter, "x\e[?1049hy").should eq("xy")
    end

    it "removes every occurrence in a run" do
      filter = Term::Mux::OutputFilter.new
      filter.on_byte('q') { Term::Mux::Disposition.drop }
      output_filtered(filter, "qaqqbq").should eq("ab")
    end
  end

  describe "replacing" do
    it "substitutes bytes for a sequence" do
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::CUP) { Term::Mux::Disposition.replace("\e[1;1H") }
      output_filtered(filter, "\e[9;9H").should eq("\e[1;1H")
    end

    it "substitutes bytes for a literal" do
      filter = Term::Mux::OutputFilter.new
      filter.on_byte('a') { Term::Mux::Disposition.replace("A".to_slice) }
      output_filtered(filter, "cab").should eq("cAb")
    end
  end

  describe "rule matching" do
    it "requires the marker to match" do
      fired  = false
      filter = Term::Mux::OutputFilter.new
      filter.on_csi('h', marker: '?', params: [1049]) do
        fired = true
        Term::Mux::Disposition.drop
      end
      output_filtered(filter, "\e[1049h").should eq("\e[1049h")
      fired.should be_false
    end

    it "requires the params to match" do
      fired  = false
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::ALT_SCREEN) do
        fired = true
        Term::Mux::Disposition.drop
      end
      output_filtered(filter, "\e[?1048h").should eq("\e[?1048h")
      fired.should be_false
    end

    it "matches any params when the rule declares none" do
      seen   = [] of Int32
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::CUP) do |token|
        seen << token.param(0)
        Term::Mux::Disposition.pass
      end
      output_filtered(filter, "\e[1;1H\e[24;80H").should eq("\e[1;1H\e[24;80H")
      seen.should eq([1, 24])
    end

    it "matches a params prefix" do
      fired  = false
      filter = Term::Mux::OutputFilter.new
      filter.on_csi('M', marker: '<', params: [0]) do
        fired = true
        Term::Mux::Disposition.pass
      end
      output_filtered(filter, "\e[<0;7;8M")
      fired.should be_true
    end

    it "takes the first matching rule" do
      order  = [] of Int32
      filter = Term::Mux::OutputFilter.new
      filter.on_csi('u', marker: '=') { order << 1; Term::Mux::Disposition.pass }
      filter.on_csi('u', marker: '=') { order << 2; Term::Mux::Disposition.pass }
      output_filtered(filter, "\e[=31u")
      order.should eq([1])
    end

    it "defaults missing params" do
      value  = -1
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::CUP) do |token|
        value = token.param(1, 1)
        Term::Mux::Disposition.pass
      end
      output_filtered(filter, "\e[5H")
      value.should eq(1)
    end

    it "ignores subparameters when parsing" do
      params = [] of Int32
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::MOUSE_SGR) do |token|
        params = [token.param(0), token.param(1), token.param(2)]
        Term::Mux::Disposition.pass
      end
      output_filtered(filter, "\e[<0:1;12;34M").should eq("\e[<0:1;12;34M")
      params.should eq([0, 12, 34])
    end
  end

  describe "sequence kinds" do
    it "dispatches ss3 sequences" do
      final  = 0_u8
      filter = Term::Mux::OutputFilter.new
      filter.on_ss3('P') do |token|
        final = token.final
        Term::Mux::Disposition.drop
      end
      output_filtered(filter, "a\eOPb").should eq("ab")
      final.should eq('P'.ord.to_u8)
    end

    it "dispatches two-byte escapes" do
      filter = Term::Mux::OutputFilter.new
      filter.on_esc('c') { Term::Mux::Disposition.drop }
      output_filtered(filter, "x\ecz").should eq("xz")
    end

    it "dispatches string sequences terminated by BEL" do
      body   = ""
      filter = Term::Mux::OutputFilter.new
      filter.on_string(']') do |token|
        body = String.new(token.bytes)
        Term::Mux::Disposition.drop
      end
      output_filtered(filter, "a\e]0;title\ab").should eq("ab")
      body.should eq("\e]0;title\a")
    end

    it "dispatches string sequences terminated by ST" do
      body   = ""
      filter = Term::Mux::OutputFilter.new
      filter.on_string(']') do |token|
        body = String.new(token.bytes)
        Term::Mux::Disposition.pass
      end
      output_filtered(filter, "\e]0;t\e\\").should eq("\e]0;t\e\\")
      body.should eq("\e]0;t\e\\")
    end

    it "reports the token kind" do
      kinds  = [] of Term::Mux::Token::Kind
      filter = Term::Mux::OutputFilter.new
      filter.on_byte('a') { |t| kinds << t.kind; Term::Mux::Disposition.pass }
      filter.on(Term::Mux::Sequences::CUP) { |t| kinds << t.kind; Term::Mux::Disposition.pass }
      filter.on_string(']') { |t| kinds << t.kind; Term::Mux::Disposition.pass }
      output_filtered(filter, "a\e[2;2H\e]0;t\a")
      kinds.should eq([
        Term::Mux::Token::Kind::Literal,
        Term::Mux::Token::Kind::Csi,
        Term::Mux::Token::Kind::StringSeq,
      ])
    end
  end

  describe "chunk boundaries" do
    it "holds an incomplete sequence until it completes" do
      fired  = 0
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::ALT_SCREEN) do
        fired += 1
        Term::Mux::Disposition.pass
      end

      output_filtered(filter, "\e[?10").should eq("")
      fired.should eq(0)
      output_filtered(filter, "49h").should eq("\e[?1049h")
      fired.should eq(1)
    end

    it "splits a sequence across three chunks" do
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::CUP) { Term::Mux::Disposition.drop }
      output_filtered(filter, "\e[1").should eq("")
      output_filtered(filter, "2;3").should eq("")
      output_filtered(filter, "4Htail").should eq("tail")
    end

    it "emits literals before an incomplete sequence" do
      filter = Term::Mux::OutputFilter.new
      output_filtered(filter, "abc\e[").should eq("abc")
      output_filtered(filter, "2J").should eq("\e[2J")
    end

    it "holds an incomplete string sequence" do
      filter = Term::Mux::OutputFilter.new
      filter.on_string(']') { Term::Mux::Disposition.drop }
      output_filtered(filter, "\e]0;par").should eq("")
      output_filtered(filter, "tial\a").should eq("")
    end

    it "flushes an oversized carry verbatim" do
      filter = Term::Mux::OutputFilter.new
      input  = "\e[" + ("1;" * 5000)
      output_filtered(filter, input).should eq(input)
      output_filtered(filter, "x").should eq("x")
    end
  end

  describe "mode pairs" do
    it "registers both directions from one call" do
      seen   = [] of Bool
      filter = Term::Mux::OutputFilter.new
      filter.on(Term::Mux::Sequences::SYNCHRONIZED) do |token|
        seen << token.set?
        Term::Mux::Disposition.pass
      end

      output_filtered(filter, "\e[?2026h\e[?2026l").should eq("\e[?2026h\e[?2026l")
      seen.should eq([true, false])
    end
  end
end
