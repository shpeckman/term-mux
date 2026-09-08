# src/mux/input_filter.cr
module Term::Mux
  struct Disposition
    enum Kind : UInt8
      Pass
      Drop
      Replace
    end

    getter kind  : Kind
    getter bytes : Bytes

    def initialize(@kind : Kind, @bytes : Bytes = Bytes.empty)
    end

    PASS = Disposition.new(Kind::Pass)
    DROP = Disposition.new(Kind::Drop)

    def self.pass : Disposition
      PASS
    end

    def self.drop : Disposition
      DROP
    end

    def self.replace(bytes : Bytes) : Disposition
      new(Kind::Replace, bytes)
    end

    def self.replace(str : String) : Disposition
      new(Kind::Replace, str.to_slice)
    end
  end

  struct Token
    enum Kind : UInt8
      Literal
      Escape
      Csi
      Ss3
      StringSeq
      Osc
      Dcs
      Apc
    end

    getter kind   : Kind
    getter bytes  : Bytes
    getter marker : UInt8
    getter final  : UInt8
    getter params : Slice(Int32)

    def initialize(@kind : Kind, @bytes : Bytes, @marker : UInt8 = 0_u8, @final : UInt8 = 0_u8,
                   @params : Slice(Int32) = Slice(Int32).empty)
    end

    def byte : UInt8
      @bytes[0]
    end

    def set? : Bool
      @final == 0x68_u8
    end

    def param(index : Int32, default : Int32 = 0) : Int32
      index < @params.size ? @params[index] : default
    end

    def content : Bytes
      case @kind
      when .string_seq?, .osc?, .apc?
        string_content(2)
      when .dcs?
        string_content(dcs_content_start)
      else
        @bytes
      end
    end

    def osc_code : Int32?
      return nil unless @kind.osc?
      value = 0
      seen  = false
      content.each do |b|
        break if b == 0x3B_u8
        return nil if b < 0x30_u8 || b > 0x39_u8
        value = value * 10 + (b - 0x30_u8).to_i32
        seen  = true
      end
      seen ? value : nil
    end

    private def string_content(start : Int32) : Bytes
      stop = @bytes.size
      if @bytes[stop - 1] == 0x07_u8
        stop -= 1
      elsif stop >= 2 && @bytes[stop - 2] == 0x1B_u8 && @bytes[stop - 1] == 0x5C_u8
        stop -= 2
      end
      stop > start ? @bytes[start, stop - start] : Bytes.empty
    end

    private def dcs_content_start : Int32
      i    = 2
      size = @bytes.size
      while i < size && @bytes[i] >= 0x30_u8 && @bytes[i] <= 0x3F_u8
        i += 1
      end
      while i < size && @bytes[i] >= 0x20_u8 && @bytes[i] <= 0x2F_u8
        i += 1
      end
      i += 1 if i < size && @bytes[i] >= 0x40_u8 && @bytes[i] <= 0x7E_u8
      i
    end

    def to_s(io : IO) : Nil
      io.write(@bytes)
    end
  end

  class InputFilter
    alias Handler = Token -> Disposition

    ESC = 0x1B_u8
    BEL = 0x07_u8

    MAX_CARRY  = 8192
    MAX_PARAMS =   16

    record CsiRule, marker : UInt8?, params : Slice(Int32), handler : Handler do
      def matches?(token : Token) : Bool
        m = @marker
        return false if m && m != token.marker
        return true if @params.empty?
        return false if @params.size > token.params.size
        i = 0
        while i < @params.size
          return false if @params[i] != token.params[i]
          i += 1
        end
        true
      end
    end

    getter? paste : Bool = false

    @carry      : Bytes
    @carry_size : Int32 = 0
    @out        : Bytes
    @out_size   : Int32 = 0

    @byte_rules      : Array(Handler?)
    @byte_rule_count : Int32    = 0
    @csi_rules       : Hash(UInt8, Array(CsiRule))
    @ss3_rules       : Hash(UInt8, Handler)
    @esc_rules       : Hash(UInt8, Handler)
    @string_rules    : Hash(UInt8, Handler)
    @osc_rules       : Hash(Int32, Handler)
    @dcs_rules       : Hash(UInt8, Handler)
    @osc_any         : Handler? = nil
    @dcs_any         : Handler? = nil
    @apc_handler     : Handler? = nil

    @params_buf : StaticArray(Int32, MAX_PARAMS)
    @pass_next  : Bool  = false
    @esc_ticks  : Int32 = 0

    def initialize(@escape_ticks : Int32 = 2)
      @carry        = Bytes.new(1024)
      @out          = Bytes.new(4096)
      @byte_rules   = Array(Handler?).new(256, nil)
      @csi_rules    = Hash(UInt8, Array(CsiRule)).new
      @ss3_rules    = Hash(UInt8, Handler).new
      @esc_rules    = Hash(UInt8, Handler).new
      @string_rules = Hash(UInt8, Handler).new
      @osc_rules    = Hash(Int32, Handler).new
      @dcs_rules    = Hash(UInt8, Handler).new
      @params_buf = uninitialized StaticArray(Int32, MAX_PARAMS)
    end

    def on(seq : Sequence, &handler : Handler) : self
      rules = (@csi_rules[seq.final] ||= [] of CsiRule)
      rules << CsiRule.new(seq.marker == 0_u8 ? nil : seq.marker, seq.params, handler)
      self
    end

    def on(pair : ModePair, &handler : Handler) : self
      on(pair.set, &handler)
      on(pair.reset, &handler)
    end

    def on_byte(byte : UInt8, &handler : Handler) : self
      @byte_rule_count += 1 unless @byte_rules[byte]
      @byte_rules[byte] = handler
      self
    end

    def on_byte(char : Char, &handler : Handler) : self
      on_byte(char.ord.to_u8, &handler)
    end

    def on_csi(final : Char, marker : Char? = nil, params : Array(Int32) = [] of Int32, &handler : Handler) : self
      slice = Slice(Int32).new(params.size) { |i| params[i] }
      rules = (@csi_rules[final.ord.to_u8] ||= [] of CsiRule)
      rules << CsiRule.new(marker.try(&.ord.to_u8), slice, handler)
      self
    end

    def on_ss3(final : Char, &handler : Handler) : self
      @ss3_rules[final.ord.to_u8] = handler
      self
    end

    def on_esc(final : Char, &handler : Handler) : self
      @esc_rules[final.ord.to_u8] = handler
      self
    end

    def on_string(introducer : Char, &handler : Handler) : self
      @string_rules[introducer.ord.to_u8] = handler
      self
    end

    def on_osc(code : Int32, &handler : Handler) : self
      @osc_rules[code] = handler
      self
    end

    def on_osc(&handler : Handler) : self
      @osc_any = handler
      self
    end

    def on_dcs(final : Char, &handler : Handler) : self
      @dcs_rules[final.ord.to_u8] = handler
      self
    end

    def on_dcs(&handler : Handler) : self
      @dcs_any = handler
      self
    end

    def on_apc(&handler : Handler) : self
      @apc_handler = handler
      self
    end

    def pass_next! : Nil
      @pass_next = true
    end

    def feed(chunk : Bytes) : Bytes
      @esc_ticks = 0
      return Bytes.empty if chunk.empty?
      if @carry_size == 0 && !@pass_next && !chunk.index(ESC) && (@paste || @byte_rule_count == 0)
        return chunk
      end
      append_carry(chunk)
      @out_size = 0
      scan
      @out[0, @out_size]
    end

    def tick : Bytes
      unless @carry_size == 1 && @carry[0] == ESC
        @esc_ticks = 0
        return Bytes.empty
      end
      @esc_ticks += 1
      return Bytes.empty if @esc_ticks < @escape_ticks
      @esc_ticks  = 0
      @out_size   = 0
      span        = @carry[0, 1]
      @carry_size = 0
      apply(Token.new(Token::Kind::Literal, span), @byte_rules[ESC]) unless guarded?(span)
      @out[0, @out_size]
    end

    private def scan : Nil
      pos  = 0
      size = @carry_size
      while pos < size
        if @carry[pos] == ESC
          len = sequence_length(pos, size)
          break if len == 0
          dispatch_sequence(pos, len)
          pos += len
        else
          stop = literal_end(pos, size)
          dispatch_literal(pos, stop)
          pos = stop
        end
      end
      consume(pos)
    end

    private def literal_end(pos : Int32, size : Int32) : Int32
      idx = @carry[pos, size - pos].index(ESC)
      idx ? pos + idx : size
    end

    private def sequence_length(pos : Int32, size : Int32) : Int32
      return 0 if pos + 1 >= size
      case @carry[pos + 1]
      when 0x5B_u8
        i = pos + 2
        while i < size && @carry[i] >= 0x30_u8 && @carry[i] <= 0x3F_u8
          i += 1
        end
        while i < size && @carry[i] >= 0x20_u8 && @carry[i] <= 0x2F_u8
          i += 1
        end
        return 0 if i >= size
        (@carry[i] >= 0x40_u8 && @carry[i] <= 0x7E_u8) ? i + 1 - pos : 2
      when 0x4F_u8
        pos + 2 < size ? 3 : 0
      when 0x5D_u8, 0x50_u8, 0x5E_u8, 0x5F_u8, 0x58_u8
        string_length(pos, size)
      else
        2
      end
    end

    private def string_length(pos : Int32, size : Int32) : Int32
      osc = @carry[pos + 1] == 0x5D_u8
      i   = pos + 2
      while i < size
        b = @carry[i]
        return i + 1 - pos if osc && b == BEL
        if b == ESC
          return 0 if i + 1 >= size
          return @carry[i + 1] == 0x5C_u8 ? i + 2 - pos : i - pos
        end
        i += 1
      end
      0
    end

    private def dispatch_sequence(pos : Int32, len : Int32) : Nil
      span = @carry[pos, len]
      if len >= 3 && span[1] == 0x5B_u8
        dispatch_csi(span)
        return
      end
      return if guarded?(span)
      case span[1]
      when 0x4F_u8
        final = span[2]
        apply(Token.new(Token::Kind::Ss3, span, 0_u8, final), @ss3_rules[final]?)
      when 0x5D_u8
        dispatch_osc(span)
      when 0x50_u8
        dispatch_dcs(span)
      when 0x5F_u8
        apply(Token.new(Token::Kind::Apc, span, 0x5F_u8), @apc_handler || @string_rules[0x5F_u8]?)
      when 0x5E_u8, 0x58_u8
        intro = span[1]
        apply(Token.new(Token::Kind::StringSeq, span, intro), @string_rules[intro]?)
      else
        final = span[1]
        apply(Token.new(Token::Kind::Escape, span, 0_u8, final), @esc_rules[final]?)
      end
    end

    private def dispatch_osc(span : Bytes) : Nil
      token   = Token.new(Token::Kind::Osc, span, 0x5D_u8)
      code    = token.osc_code
      handler = code ? @osc_rules[code]? : nil
      handler ||= @osc_any
      handler ||= @string_rules[0x5D_u8]?
      apply(token, handler)
    end

    private def dispatch_dcs(span : Bytes) : Nil
      final   = dcs_final(span)
      handler = @dcs_rules[final]?
      handler ||= @dcs_any
      handler ||= @string_rules[0x50_u8]?
      apply(Token.new(Token::Kind::Dcs, span, 0x50_u8, final), handler)
    end

    private def dcs_final(span : Bytes) : UInt8
      i = 2
      while i < span.size && span[i] >= 0x30_u8 && span[i] <= 0x3F_u8
        i += 1
      end
      while i < span.size && span[i] >= 0x20_u8 && span[i] <= 0x2F_u8
        i += 1
      end
      if i < span.size && span[i] >= 0x40_u8 && span[i] <= 0x7E_u8
        span[i]
      else
        0_u8
      end
    end

    private def dispatch_csi(span : Bytes) : Nil
      final = span[span.size - 1]
      body  = span[2, span.size - 3]

      marker = 0_u8
      if body.size > 0 && body[0] >= 0x3C_u8 && body[0] <= 0x3F_u8
        marker = body[0]
        body   = body[1, body.size - 1]
      end

      count = parse_params(body)

      if final == 0x7E_u8 && marker == 0_u8 && count == 1
        case @params_buf[0]
        when 200
          @paste = true
          emit(span)
          return
        when 201
          @paste = false
          emit(span)
          return
        end
      end

      return if guarded?(span)

      token   = Token.new(Token::Kind::Csi, span, marker, final, @params_buf.to_slice[0, count])
      handler = nil.as(Handler?)
      if rules = @csi_rules[final]?
        rules.each do |rule|
          if rule.matches?(token)
            handler = rule.handler
            break
          end
        end
      end
      apply(token, handler)
    end

    private def parse_params(body : Bytes) : Int32
      count = 0
      value = 0
      seen  = false
      skip  = false
      body.each do |b|
        case b
        when 0x30_u8..0x39_u8
          unless skip
            value = value * 10 + (b - 0x30_u8).to_i32
            seen  = true
          end
        when 0x3B_u8
          break if count >= MAX_PARAMS
          @params_buf[count] = value
          count += 1
          value = 0
          seen  = false
          skip  = false
        when 0x3A_u8
          skip = true
        else
          break
        end
      end
      if (seen || count > 0) && count < MAX_PARAMS
        @params_buf[count] = value
        count += 1
      end
      count
    end

    private def dispatch_literal(pos : Int32, stop : Int32) : Nil
      run = @carry[pos, stop - pos]
      if @paste || (@byte_rule_count == 0 && !@pass_next)
        emit(run)
        return
      end
      start = 0
      i     = 0
      while i < run.size
        handler = @byte_rules[run[i]]
        if @pass_next || handler
          emit(run[start, i - start]) if i > start
          single = run[i, 1]
          if @pass_next
            @pass_next = false
            emit(single)
          else
            apply(Token.new(Token::Kind::Literal, single), handler)
          end
          start = i + 1
        end
        i += 1
      end
      emit(run[start, run.size - start]) if start < run.size
    end

    private def guarded?(span : Bytes) : Bool
      if @paste
        emit(span)
        return true
      end
      if @pass_next
        @pass_next = false
        emit(span)
        return true
      end
      false
    end

    private def apply(token : Token, handler : Handler?) : Nil
      unless handler
        emit(token.bytes)
        return
      end
      disposition = handler.call(token)
      case disposition.kind
      in Disposition::Kind::Pass    then emit(token.bytes)
      in Disposition::Kind::Drop    then nil
      in Disposition::Kind::Replace then emit(disposition.bytes)
      end
    end

    private def append_carry(chunk : Bytes) : Nil
      needed = @carry_size + chunk.size
      if needed > @carry.size
        cap = @carry.size
        while cap < needed
          cap *= 2
        end
        grown = Bytes.new(cap)
        @carry.to_unsafe.copy_to(grown.to_unsafe, @carry_size)
        @carry = grown
      end
      chunk.copy_to(@carry.to_unsafe + @carry_size, chunk.size)
      @carry_size = needed
    end

    private def consume(pos : Int32) : Nil
      remaining = @carry_size - pos
      if remaining > 0 && pos > 0
        (@carry.to_unsafe + pos).move_to(@carry.to_unsafe, remaining)
      end
      if remaining > MAX_CARRY
        emit(@carry[0, remaining])
        remaining = 0
      end
      @carry_size = remaining
    end

    private def emit(bytes : Bytes) : Nil
      return if bytes.empty?
      needed = @out_size + bytes.size
      if needed > @out.size
        cap = @out.size
        while cap < needed
          cap *= 2
        end
        grown = Bytes.new(cap)
        @out.to_unsafe.copy_to(grown.to_unsafe, @out_size)
        @out = grown
      end
      bytes.copy_to(@out.to_unsafe + @out_size, bytes.size)
      @out_size = needed
    end
  end
end
