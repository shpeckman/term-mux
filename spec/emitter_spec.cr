# spec/emitter_spec.cr
require "./spec_helper"

describe Term::Mux::Emitter do
  describe "buffer" do
    it "starts empty" do
      em = Term::Mux::Emitter.new
      em.empty?.should be_true
      em.size.should eq(0)
    end

    it "appends raw bytes and strings" do
      em = Term::Mux::Emitter.new
      em.raw("ab").raw("cd".to_slice)
      rendered(em).should eq("abcd")
      em.size.should eq(4)
    end

    it "appends through the shovel operator" do
      em = Term::Mux::Emitter.new
      em << "x" << "y".to_slice
      rendered(em).should eq("xy")
    end

    it "writes single bytes and numbers" do
      em = Term::Mux::Emitter.new
      em.byte(0x41_u8).num(1234).num(0).num(-5)
      rendered(em).should eq("A123400")
    end

    it "resets without returning bytes" do
      em = Term::Mux::Emitter.new
      em.raw("data").reset
      em.empty?.should be_true
      rendered(em).should eq("")
    end

    it "takes the buffer and clears it" do
      em = Term::Mux::Emitter.new
      em.raw("frame")
      String.new(em.take).should eq("frame")
      em.size.should eq(0)
    end

    it "grows from a zero capacity" do
      em = Term::Mux::Emitter.new(0)
      em.raw("x" * 5000)
      em.size.should eq(5000)
      rendered(em).should eq("x" * 5000)
    end

    it "chains every writer" do
      em = Term::Mux::Emitter.new
      em.home.sgr_reset.text("hi")
      rendered(em).should eq("\e[H\e[0m" + "hi")
    end
  end

  describe "static declarations" do
    it "emits a preallocated constant" do
      em = Term::Mux::Emitter.new
      em.home
      rendered(em).should eq("\e[H")
    end

    it "emits fixed params" do
      em = Term::Mux::Emitter.new
      em.sgr_reset
      rendered(em).should eq("\e[0m")
    end
  end

  describe "decset declarations" do
    it "emits both directions" do
      em = Term::Mux::Emitter.new
      em.alt_screen(true).alt_screen(false)
      rendered(em).should eq("\e[?1049h\e[?1049l")
    end

    it "emits by mode pair" do
      em = Term::Mux::Emitter.new
      em.mode(Term::Mux::Sequences::FOCUS_EVENTS, true)
      rendered(em).should eq("\e[?1004h")
    end

    it "wraps a block for paired declarations" do
      em = Term::Mux::Emitter.new
      em.synchronized { em.text("body") }
      rendered(em).should eq("\e[?2026hbody\e[?2026l")
    end

    it "wraps a block for any mode pair" do
      em = Term::Mux::Emitter.new
      em.mode(Term::Mux::Sequences::CURSOR_VISIBLE) { em.text("x") }
      rendered(em).should eq("\e[?25hx\e[?25l")
    end
  end

  describe "parameterized declarations" do
    it "writes params in order" do
      em = Term::Mux::Emitter.new
      em.mouse_sgr(0, 12, 34)
      rendered(em).should eq("\e[<0;12;34M")
    end

    it "writes a private marker" do
      em = Term::Mux::Emitter.new
      em.kitty_keyboard(31)
      rendered(em).should eq("\e[=31u")
    end

    it "writes zero params" do
      em = Term::Mux::Emitter.new
      em.kitty_keyboard(0)
      rendered(em).should eq("\e[=0u")
    end

    it "elides every default" do
      em = Term::Mux::Emitter.new
      em.cup(1, 1)
      rendered(em).should eq("\e[H")
    end

    it "elides leading defaults only" do
      em = Term::Mux::Emitter.new
      em.cup(1, 5)
      rendered(em).should eq("\e[;5H")
    end

    it "keeps all params when none are default" do
      em = Term::Mux::Emitter.new
      em.cup(3, 5)
      rendered(em).should eq("\e[3;5H")
    end

    it "elides trailing defaults" do
      em = Term::Mux::Emitter.new
      em.cup(3, 1)
      rendered(em).should eq("\e[3H")
    end

    it "elides single defaults" do
      em = Term::Mux::Emitter.new
      em.cursor_up(1).cursor_down(2).erase_line(0).erase_display(2)
      rendered(em).should eq("\e[A\e[2B\e[K\e[2J")
    end

    it "writes multi-digit params" do
      em = Term::Mux::Emitter.new
      em.cup(120, 4096)
      rendered(em).should eq("\e[120;4096H")
    end
  end

  describe "osc declarations" do
    it "terminates with ST by default" do
      em = Term::Mux::Emitter.new
      em.title("hi")
      rendered(em).should eq("\e]0;hi\e\\")
    end

    it "terminates with BEL when configured" do
      em = Term::Mux::Emitter.new(256, Term::Mux::Emitter::StringTerminator::Bel)
      em.title("hi")
      rendered(em).should eq("\e]0;hi\a")
    end

    it "follows a terminator change" do
      em = Term::Mux::Emitter.new
      em.string_terminator = Term::Mux::Emitter::StringTerminator::Bel
      em.title("x")
      rendered(em).should eq("\e]0;x\a")
    end

    it "writes utf-8 payloads verbatim" do
      em = Term::Mux::Emitter.new
      em.title("héllo →")
      rendered(em).should eq("\e]0;héllo →\e\\")
    end
  end

  describe "emitter and filter agreement" do
    it "emits bytes the filter parses back to the declaration" do
      em = Term::Mux::Emitter.new
      em.focus_events(true)

      seen   = 0
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::FOCUS_EVENTS) do |token|
        seen += 1
        token.set?.should be_true
        Term::Mux::Disposition.pass
      end

      filtered(filter, em.bytes).should eq("\e[?1004h")
      seen.should eq(1)
    end

    it "round-trips parameterized sequences" do
      em = Term::Mux::Emitter.new
      em.mouse_sgr(2, 40, 9)

      params = [] of Int32
      filter = Term::Mux::InputFilter.new
      filter.on(Term::Mux::Sequences::MOUSE_SGR) do |token|
        params = [token.param(0), token.param(1), token.param(2)]
        Term::Mux::Disposition.pass
      end

      filtered(filter, em.bytes)
      params.should eq([2, 40, 9])
    end
  end
end
