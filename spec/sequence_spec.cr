# spec/sequence_spec.cr
require "./spec_helper"

describe Term::Mux::Sequence do
  it "exposes marker and final as characters" do
    seq = Term::Mux::Sequences::MOUSE_SGR
    seq.marker_char.should eq('<')
    seq.final_char.should eq('M')
  end

  it "reports no marker as nil" do
    Term::Mux::Sequences::HOME.marker_char.should be_nil
  end

  it "carries fixed params for static declarations" do
    Term::Mux::Sequences::SGR_RESET.params.should eq(Slice[0])
  end

  it "leaves params empty for parameterized declarations" do
    Term::Mux::Sequences::MOUSE_SGR.params.empty?.should be_true
    Term::Mux::Sequences::CUP.params.empty?.should be_true
  end
end

describe Term::Mux::ModePair do
  it "records the mode number" do
    Term::Mux::Sequences::FOCUS_EVENTS.mode.should eq(1004)
  end

  it "builds both directions from one declaration" do
    pair = Term::Mux::Sequences::FOCUS_EVENTS
    String.new(pair.set_bytes).should eq("\e[?1004h")
    String.new(pair.reset_bytes).should eq("\e[?1004l")
  end

  it "selects bytes by direction" do
    pair = Term::Mux::Sequences::ALT_SCREEN
    String.new(pair.bytes(true)).should eq("\e[?1049h")
    String.new(pair.bytes(false)).should eq("\e[?1049l")
  end

  it "describes each direction as a matchable sequence" do
    pair = Term::Mux::Sequences::BRACKETED_PASTE
    pair.set.marker_char.should eq('?')
    pair.set.final_char.should eq('h')
    pair.reset.final_char.should eq('l')
    pair.set.params.should eq(Slice[2004])
  end
end
