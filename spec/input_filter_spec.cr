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

    it "requires an unmarked rule to see an unmarked sequence" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') do
        fired = true
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\e[?31u").should eq("\e[?31u")
      fired.should be_false
      filtered(filter, "\e[27u").should eq("")
      fired.should be_true
    end

    it "requires a static declaration to see an unmarked sequence" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::CUP) do
        fired = true
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\e[?1;1H").should eq("\e[?1;1H")
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

    it "matches params against the first value of each group" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u', params: [27]) do
        fired = true
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\e[27:1:2;5u").should eq("")
      fired.should be_true
    end

    it "does not match a rule param against an omitted group" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u', params: [97, 0]) do
        fired = true
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\e[97;;99u").should eq("\e[97;;99u")
      fired.should be_false
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
  end

  describe "parameter groups" do
    it "reads the first value of each group" do
      params = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::MOUSE_SGR) do |token|
        params = [token.param(0), token.param(1), token.param(2)]
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[<0:1;12;34M").should eq("\e[<0:1;12;34M")
      params.should eq([0, 12, 34])
    end

    it "reports the group count" do
      groups = -1
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') { |t| groups = t.groups; Term::Mux::Disposition.pass }
      filtered(filter, "\e[27:1:2;5:3u")
      groups.should eq(2)
    end

    it "exposes subparameters" do
      subs   = [] of Int32?
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') do |t|
        subs = [t.sub?(0, 0), t.sub?(0, 1), t.sub?(0, 2), t.sub?(1, 0), t.sub?(1, 1)]
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[27:1:2;5:3u")
      subs.should eq([27, 1, 2, 5, 3])
    end

    it "counts the subparameters of each group" do
      counts = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') do |t|
        counts = [t.sub_count(0), t.sub_count(1), t.sub_count(2)]
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[27:1:2;5u")
      counts.should eq([3, 1, 0])
    end

    it "defaults a missing subparameter" do
      value  = -1
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') { |t| value = t.sub(0, 2, 1); Term::Mux::Disposition.pass }
      filtered(filter, "\e[27:1u")
      value.should eq(1)
    end

    it "reports an omitted group as nil" do
      values = [] of Int32?
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') do |t|
        values = [t.param?(0), t.param?(1), t.param?(2)]
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[97;;99u")
      values.should eq([97, nil, 99])
    end

    it "defaults an omitted leading group" do
      params = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::CUP) do |token|
        params = [token.param(0, 1), token.param(1, 1)]
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[;5H")
      params.should eq([1, 5])
    end

    it "defaults an omitted trailing group" do
      params = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::CUP) do |token|
        params = [token.param(0, 1), token.param(1, 1)]
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[3;H")
      params.should eq([3, 1])
    end

    it "reports no groups for an empty parameter list" do
      groups = -1
      value  = -1
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::CUP) do |token|
        groups = token.groups
        value  = token.param(0, 1)
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[H")
      groups.should eq(0)
      value.should eq(1)
    end

    it "returns nil beyond the last group" do
      values = [] of Int32?
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') do |t|
        values = [t.param?(3), t.sub?(0, 4), t.sub?(-1, 0)]
        Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[27:1;5u")
      values.should eq([nil, nil, nil])
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

  describe "catch-all rules" do
    it "dispatches unmatched csi sequences" do
      finals = [] of Char
      filter = Term::Mux::InputFilter.new
      filter.on_csi { |t| finals << t.final.unsafe_chr; Term::Mux::Disposition.pass }
      filtered(filter, "\e[2J\e[?1049h").should eq("\e[2J\e[?1049h")
      finals.should eq(['J', 'h'])
    end

    it "prefers a specific csi rule over the catch-all" do
      hits   = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on_csi { hits << 0; Term::Mux::Disposition.pass }
      filter.on(Term::Mux::Sequences::CUP) { hits << 1; Term::Mux::Disposition.pass }
      filtered(filter, "\e[1;1H\e[2J")
      hits.should eq([1, 0])
    end

    it "drops through the csi catch-all" do
      filter = Term::Mux::InputFilter.new
      filter.on_csi { Term::Mux::Disposition.drop }
      filtered(filter, "a\e[2Jb").should eq("ab")
    end

    it "does not intercept the paste markers" do
      finals = [] of Char
      filter = Term::Mux::InputFilter.new
      filter.on_csi { |t| finals << t.final.unsafe_chr; Term::Mux::Disposition.drop }
      filtered(filter, "\e[200~a\e[201~").should eq("\e[200~a\e[201~")
      finals.empty?.should be_true
    end

    it "dispatches unmatched ss3 sequences" do
      filter = Term::Mux::InputFilter.new
      filter.on_ss3 { Term::Mux::Disposition.drop }
      filtered(filter, "a\eOPb").should eq("ab")
    end

    it "prefers a specific ss3 rule over the catch-all" do
      hits   = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on_ss3 { hits << 0; Term::Mux::Disposition.pass }
      filter.on_ss3('P') { hits << 1; Term::Mux::Disposition.pass }
      filtered(filter, "\eOP\eOQ")
      hits.should eq([1, 0])
    end

    it "dispatches unmatched two-byte escapes" do
      filter = Term::Mux::InputFilter.new
      filter.on_esc { Term::Mux::Disposition.drop }
      filtered(filter, "x\ebz").should eq("xz")
    end

    it "prefers a specific esc rule over the catch-all" do
      hits   = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on_esc { hits << 0; Term::Mux::Disposition.pass }
      filter.on_esc('b') { hits << 1; Term::Mux::Disposition.pass }
      filtered(filter, "\eb\ec")
      hits.should eq([1, 0])
    end
  end

  describe "token bytes" do
    it "copies the span into fresh storage" do
      copy   = Bytes.empty
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') { |t| copy = t.copy; Term::Mux::Disposition.pass }

      input = Bytes.new(5)
      "\e[27u".to_slice.copy_to(input)
      filtered(filter, input).should eq("\e[27u")
      String.new(copy).should eq("\e[27u")

      input[2] = '9'.ord.to_u8
      String.new(copy).should eq("\e[27u")
    end

    it "copies a literal token" do
      copy   = Bytes.empty
      filter = Term::Mux::InputFilter.new
      filter.on_byte('a') { |t| copy = t.copy; Term::Mux::Disposition.pass }
      filtered(filter, "a")
      String.new(copy).should eq("a")
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

    it "splits a subparameter group across chunks" do
      subs   = [] of Int32?
      filter = Term::Mux::InputFilter.new
      filter.on_csi('u') do |t|
        subs = [t.sub?(0, 0), t.sub?(0, 1), t.param?(1)]
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\e[27:").should eq("")
      filtered(filter, "1;5").should eq("")
      filtered(filter, "u").should eq("")
      subs.should eq([27, 1, 5])
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

  describe "paste tokens" do
    it "dispatches start, data and end tokens" do
      kinds  = [] of Term::Mux::Token::Kind
      body   = ""
      filter = Term::Mux::InputFilter.new
      filter.on_paste do |token|
        kinds << token.kind
        body += String.new(token.bytes) if token.kind.paste_data?
        Term::Mux::Disposition.pass
      end

      filtered(filter, "\e[200~hello\e[201~").should eq("\e[200~hello\e[201~")
      kinds.should eq([
        Term::Mux::Token::Kind::PasteStart,
        Term::Mux::Token::Kind::PasteData,
        Term::Mux::Token::Kind::PasteEnd,
      ])
      body.should eq("hello")
    end

    it "dispatches data from a chunk with no escapes" do
      chunks = [] of String
      filter = Term::Mux::InputFilter.new
      filter.on_paste do |token|
        chunks << String.new(token.bytes) if token.kind.paste_data?
        Term::Mux::Disposition.pass
      end

      filtered(filter, "\e[200~").should eq("\e[200~")
      filtered(filter, "plain text").should eq("plain text")
      chunks.should eq(["plain text"])
    end

    it "spans chunk boundaries" do
      chunks = [] of String
      filter = Term::Mux::InputFilter.new
      filter.on_paste do |token|
        chunks << String.new(token.bytes) if token.kind.paste_data?
        Term::Mux::Disposition.pass
      end

      filtered(filter, "\e[200~one").should eq("\e[200~one")
      filtered(filter, "two\e[201~").should eq("two\e[201~")
      chunks.should eq(["one", "two"])
    end

    it "drops the pasted content" do
      filter = Term::Mux::InputFilter.new
      filter.on_paste { Term::Mux::Disposition.drop }
      filtered(filter, "a\e[200~text\e[201~b").should eq("ab")
    end

    it "replaces the pasted content" do
      filter = Term::Mux::InputFilter.new
      filter.on_paste do |token|
        token.kind.paste_data? ? Term::Mux::Disposition.replace("X") : Term::Mux::Disposition.pass
      end
      filtered(filter, "\e[200~text\e[201~").should eq("\e[200~X\e[201~")
    end

    it "delivers sequences inside a paste as data" do
      fired  = false
      kinds  = [] of Term::Mux::Token::Kind
      filter = Term::Mux::InputFilter.new
      filter.on_paste { |t| kinds << t.kind; Term::Mux::Disposition.pass }
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) do
        fired = true
        Term::Mux::Disposition.drop
      end

      filtered(filter, "\e[200~\e[?1004h\e[201~").should eq("\e[200~\e[?1004h\e[201~")
      fired.should be_false
      kinds.should eq([
        Term::Mux::Token::Kind::PasteStart,
        Term::Mux::Token::Kind::PasteData,
        Term::Mux::Token::Kind::PasteEnd,
      ])
    end

    it "delivers a nested start marker as data" do
      kinds  = [] of Term::Mux::Token::Kind
      filter = Term::Mux::InputFilter.new
      filter.on_paste { |t| kinds << t.kind; Term::Mux::Disposition.pass }

      filtered(filter, "\e[200~a\e[200~b\e[201~").should eq("\e[200~a\e[200~b\e[201~")
      kinds.should eq([
        Term::Mux::Token::Kind::PasteStart,
        Term::Mux::Token::Kind::PasteData,
        Term::Mux::Token::Kind::PasteData,
        Term::Mux::Token::Kind::PasteData,
        Term::Mux::Token::Kind::PasteEnd,
      ])
    end

    it "still tracks the paste state" do
      filter = Term::Mux::InputFilter.new
      filter.on_paste { Term::Mux::Disposition.pass }
      filter.paste?.should be_false
      filtered(filter, "\e[200~")
      filter.paste?.should be_true
      filtered(filter, "\e[201~")
      filter.paste?.should be_false
    end

    it "suppresses byte rules inside a paste" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_paste { Term::Mux::Disposition.pass }
      filter.on_byte(0x02_u8) do
        fired = true
        Term::Mux::Disposition.drop
      end

      filtered(filter, "\e[200~a\x02b\e[201~").should eq("\e[200~a\x02b\e[201~")
      fired.should be_false
    end
  end

  describe "osc" do
    it "dispatches by numeric code" do
      body   = ""
      filter = Term::Mux::InputFilter.new
      filter.on_osc(0) do |token|
        body = String.new(token.content)
        Term::Mux::Disposition.drop
      end
      filtered(filter, "a\e]0;term\ab").should eq("ab")
      body.should eq("0;term")
    end

    it "ignores other codes" do
      filter = Term::Mux::InputFilter.new
      filter.on_osc(0) { Term::Mux::Disposition.drop }
      filtered(filter, "\e]2;other\a").should eq("\e]2;other\a")
    end

    it "falls back to the catch-all handler" do
      codes  = [] of Int32?
      filter = Term::Mux::InputFilter.new
      filter.on_osc { |t| codes << t.osc_code; Term::Mux::Disposition.drop }
      filtered(filter, "\e]0;a\a\e]52;c;eA==\a").should eq("")
      codes.should eq([0, 52])
    end

    it "prefers a code rule over the catch-all" do
      hits   = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on_osc { hits << 0; Term::Mux::Disposition.pass }
      filter.on_osc(8) { hits << 8; Term::Mux::Disposition.pass }
      filtered(filter, "\e]8;;x\e\\\e]9;y\a")
      hits.should eq([8, 0])
    end

    it "falls back to on_string for the introducer" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_string(']') { fired = true; Term::Mux::Disposition.drop }
      filtered(filter, "\e]0;t\a").should eq("")
      fired.should be_true
    end

    it "handles ST termination" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_osc(0) { fired = true; Term::Mux::Disposition.drop }
      filtered(filter, "\e]0;t\e\\").should eq("")
      fired.should be_true
    end

    it "reports the osc token kind" do
      kind   = nil
      filter = Term::Mux::InputFilter.new
      filter.on_osc { |t| kind = t.kind; Term::Mux::Disposition.pass }
      filtered(filter, "\e]0;t\a")
      kind.should eq(Term::Mux::Token::Kind::Osc)
    end

    it "holds an incomplete sequence across chunks" do
      fired  = 0
      filter = Term::Mux::InputFilter.new
      filter.on_osc(0) { fired += 1; Term::Mux::Disposition.drop }
      filtered(filter, "\e]0;ti").should eq("")
      filtered(filter, "tle\ax").should eq("x")
      fired.should eq(1)
    end

    it "returns nil osc_code for a non-numeric code" do
      code   = 0
      filter = Term::Mux::InputFilter.new
      filter.on_osc { |t| code = t.osc_code; Term::Mux::Disposition.pass }
      filtered(filter, "\e]abc\a")
      code.should be_nil
    end
  end

  describe "dcs" do
    it "dispatches by final byte" do
      body   = ""
      filter = Term::Mux::InputFilter.new
      filter.on_dcs('q') do |token|
        body = String.new(token.content)
        Term::Mux::Disposition.drop
      end
      filtered(filter, "a\ePq123\e\\b").should eq("ab")
      body.should eq("123")
    end

    it "dispatches with params and intermediates" do
      finals = [] of UInt8
      filter = Term::Mux::InputFilter.new
      filter.on_dcs('r') do |token|
        finals << token.final
        Term::Mux::Disposition.drop
      end
      filtered(filter, "\eP0$rdata\e\\").should eq("")
      finals.should eq(['r'.ord.to_u8])
    end

    it "ignores other final bytes" do
      filter = Term::Mux::InputFilter.new
      filter.on_dcs('q') { Term::Mux::Disposition.drop }
      filtered(filter, "\ePrx\e\\").should eq("\ePrx\e\\")
    end

    it "falls back to the catch-all handler" do
      fired  = 0
      filter = Term::Mux::InputFilter.new
      filter.on_dcs { fired += 1; Term::Mux::Disposition.drop }
      filtered(filter, "\ePqa\e\\\ePqb\e\\").should eq("")
      fired.should eq(2)
    end

    it "prefers a final-byte rule over the catch-all" do
      hits   = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on_dcs { hits << 0; Term::Mux::Disposition.pass }
      filter.on_dcs('q') { hits << 1; Term::Mux::Disposition.pass }
      filtered(filter, "\ePqa\e\\\ePrb\e\\")
      hits.should eq([1, 0])
    end

    it "falls back to on_string for the introducer" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_string('P') { fired = true; Term::Mux::Disposition.drop }
      filtered(filter, "\ePqx\e\\").should eq("")
      fired.should be_true
    end

    it "reports the dcs token kind" do
      kind   = nil
      filter = Term::Mux::InputFilter.new
      filter.on_dcs { |t| kind = t.kind; Term::Mux::Disposition.pass }
      filtered(filter, "\ePq1\e\\")
      kind.should eq(Term::Mux::Token::Kind::Dcs)
    end

    it "holds an incomplete sequence across chunks" do
      fired  = 0
      filter = Term::Mux::InputFilter.new
      filter.on_dcs('q') { fired += 1; Term::Mux::Disposition.drop }
      filtered(filter, "\ePq12").should eq("")
      filtered(filter, "3\e\\x").should eq("x")
      fired.should eq(1)
    end
  end

  describe "apc" do
    it "dispatches apc sequences" do
      body   = ""
      filter = Term::Mux::InputFilter.new
      filter.on_apc do |token|
        body = String.new(token.content)
        Term::Mux::Disposition.drop
      end
      filtered(filter, "a\e_Gpayload\e\\b").should eq("ab")
      body.should eq("Gpayload")
    end

    it "falls back to on_string for the introducer" do
      fired  = false
      filter = Term::Mux::InputFilter.new
      filter.on_string('_') { fired = true; Term::Mux::Disposition.drop }
      filtered(filter, "\e_x\e\\").should eq("")
      fired.should be_true
    end

    it "reports the apc token kind" do
      kind   = nil
      filter = Term::Mux::InputFilter.new
      filter.on_apc { |t| kind = t.kind; Term::Mux::Disposition.pass }
      filtered(filter, "\e_x\e\\")
      kind.should eq(Term::Mux::Token::Kind::Apc)
    end

    it "holds an incomplete sequence across chunks" do
      fired  = 0
      filter = Term::Mux::InputFilter.new
      filter.on_apc { fired += 1; Term::Mux::Disposition.drop }
      filtered(filter, "\e_Gpa").should eq("")
      filtered(filter, "y\e\\x").should eq("x")
      fired.should eq(1)
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
