# src/mux/sequence.cr
module Term::Mux
  struct Sequence
    getter marker : UInt8
    getter final  : UInt8
    getter params : Slice(Int32)

    def initialize(@marker : UInt8, @final : UInt8, @params : Slice(Int32) = Slice(Int32).empty)
    end

    def marker_char : Char?
      @marker == 0_u8 ? nil : @marker.unsafe_chr
    end

    def final_char : Char
      @final.unsafe_chr
    end
  end

  struct ModePair
    getter mode        : Int32
    getter set         : Sequence
    getter reset       : Sequence
    getter set_bytes   : Bytes
    getter reset_bytes : Bytes

    def initialize(@mode : Int32, @set : Sequence, @reset : Sequence,
                   @set_bytes : Bytes, @reset_bytes : Bytes)
    end

    def bytes(on : Bool) : Bytes
      on ? @set_bytes : @reset_bytes
    end
  end

  module Sequences
  end
end
