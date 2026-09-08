# src/mux/filter.cr
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
end

class Term::Mux::InputFilter
  alias Handler = Token -> Disposition

  ESC = 0x1B_u8
  BEL = 0x07_u8

  MAX_CARRY  = 8192
  MAX_PARAMS =   16
  TABLE      =  256
  SCAN_LIST  =    4
  SCAN_MIN   =   32

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

  @src        : Bytes = Bytes.empty
  @carry      : Bytes
  @carry_off  : Int32 = 0
  @carry_size : Int32 = 0
  @out        : Bytes
  @out_size   : Int32 = 0
  @copying    : Bool  = false
  @passed     : Int32 = 0

  @byte_rules      : Array(Handler?)
  @byte_mask       : StaticArray(UInt64, 4)
  @byte_list       : StaticArray(UInt8, SCAN_LIST)
  @byte_list_size  : Int32 = 0
  @byte_rule_count : Int32 = 0

  @csi_rules    : Array(Array(CsiRule)?)
  @ss3_rules    : Array(Handler?)
  @esc_rules    : Array(Handler?)
  @string_rules : Array(Handler?)
  @dcs_rules    : Array(Handler?)
  @osc_rules    : Hash(Int32, Handler)
  @osc_any      : Handler? = nil
  @dcs_any      : Handler? = nil
  @apc_handler  : Handler? = nil

  @params_buf : StaticArray(Int32, MAX_PARAMS)
  @pass_next  : Bool  = false
  @esc_ticks  : Int32 = 0

  def initialize(@escape_ticks : Int32 = 2)
    @carry        = Buffer.alloc(1024)
    @out          = Buffer.alloc(4096)
    @byte_rules   = Array(Handler?).new(TABLE, nil)
    @csi_rules    = Array(Array(CsiRule)?).new(TABLE, nil)
    @ss3_rules    = Array(Handler?).new(TABLE, nil)
    @esc_rules    = Array(Handler?).new(TABLE, nil)
    @string_rules = Array(Handler?).new(TABLE, nil)
    @dcs_rules    = Array(Handler?).new(TABLE, nil)
    @osc_rules    = Hash(Int32, Handler).new
    @byte_mask    = StaticArray(UInt64, 4).new(0_u64)
    @byte_list = uninitialized StaticArray(UInt8, SCAN_LIST)
    @params_buf = uninitialized StaticArray(Int32, MAX_PARAMS)
  end

  def on(seq : Sequence, &handler : Handler) : self
    add_csi(seq.final, seq.marker == 0_u8 ? nil : seq.marker, seq.params, handler)
    self
  end

  def on(pair : ModePair, &handler : Handler) : self
    on(pair.set, &handler)
    on(pair.reset, &handler)
  end

  def on_byte(byte : UInt8, &handler : Handler) : self
    unless marked?(byte)
      mark(byte)
      @byte_rule_count += 1
      if @byte_list_size < SCAN_LIST
        @byte_list[@byte_list_size] = byte
        @byte_list_size += 1
      end
    end
    @byte_rules[byte] = handler
    self
  end

  def on_byte(char : Char, &handler : Handler) : self
    on_byte(char.ord.to_u8, &handler)
  end

  def on_csi(final : Char, marker : Char? = nil, params : Array(Int32) = [] of Int32, &handler : Handler) : self
    slice = Slice(Int32).new(params.size) { |i| params[i] }
    add_csi(final.ord.to_u8, marker.try(&.ord.to_u8), slice, handler)
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
    if @carry_size == 0
      @carry_off = 0
      if !@pass_next && !chunk.index(ESC) && (@paste || @byte_rule_count == 0)
        return chunk
      end
      return feed_direct(chunk)
    end
    feed_carried(chunk)
  end

  def tick : Bytes
    unless @carry_size == 1 && @carry.to_unsafe[@carry_off] == ESC
      @esc_ticks = 0
      return Bytes.empty
    end
    @esc_ticks += 1
    return Bytes.empty if @esc_ticks < @escape_ticks

    @esc_ticks  = 0
    @out_size   = 0
    @copying    = true
    @passed     = 0
    span        = @carry[@carry_off, 1]
    @src        = span
    @carry_size = 0
    apply(Token.new(Token::Kind::Literal, span), @byte_rules.unsafe_fetch(ESC)) unless guarded?(span)
    @src = Bytes.empty
    @out[0, @out_size]
  end

  private def feed_direct(chunk : Bytes) : Bytes
    @src      = chunk
    @copying  = false
    @passed   = 0
    @out_size = 0

    pos       = scan(chunk)
    remaining = chunk.size - pos

    if remaining > MAX_CARRY
      emit_span(chunk[pos, remaining])
      remaining = 0
    end

    if remaining > 0
      ensure_carry(remaining)
      chunk[pos, remaining].copy_to(@carry.to_unsafe, remaining)
      @carry_off  = 0
      @carry_size = remaining
    end

    result = @copying ? @out[0, @out_size] : chunk[0, @passed]
    @src   = Bytes.empty
    result
  end

  private def feed_carried(chunk : Bytes) : Bytes
    append_carry(chunk)

    src       = @carry[@carry_off, @carry_size]
    @src      = src
    @copying  = false
    @passed   = 0
    @out_size = 0

    pos       = scan(src)
    remaining = @carry_size - pos

    if remaining > MAX_CARRY
      emit_span(src[pos, remaining])
      pos += remaining
      remaining = 0
    end

    @carry_off += pos
    @carry_size = remaining

    result = @copying ? @out[0, @out_size] : src[0, @passed]
    @src   = Bytes.empty
    result
  end

  private def scan(src : Bytes) : Int32
    pos  = 0
    size = src.size
    while pos < size
      if src.to_unsafe[pos] == ESC
        len = sequence_length(src, pos, size)
        break if len == 0
        dispatch_sequence(src[pos, len])
        pos += len
      else
        stop = literal_end(src, pos, size)
        dispatch_literal(src[pos, stop - pos])
        pos = stop
      end
    end
    pos
  end

  private def literal_end(src : Bytes, pos : Int32, size : Int32) : Int32
    idx = src[pos, size - pos].index(ESC)
    idx ? pos + idx : size
  end

  private def sequence_length(src : Bytes, pos : Int32, size : Int32) : Int32
    return 0 if pos + 1 >= size
    ptr = src.to_unsafe
    case ptr[pos + 1]
    when 0x5B_u8
      i = pos + 2
      while i < size && ptr[i] >= 0x30_u8 && ptr[i] <= 0x3F_u8
        i += 1
      end
      while i < size && ptr[i] >= 0x20_u8 && ptr[i] <= 0x2F_u8
        i += 1
      end
      return 0 if i >= size
      (ptr[i] >= 0x40_u8 && ptr[i] <= 0x7E_u8) ? i + 1 - pos : 2
    when 0x4F_u8
      pos + 2 < size ? 3 : 0
    when 0x5D_u8, 0x50_u8, 0x5E_u8, 0x5F_u8, 0x58_u8
      string_length(src, pos, size)
    else
      2
    end
  end

  private def string_length(src : Bytes, pos : Int32, size : Int32) : Int32
    ptr = src.to_unsafe
    osc = ptr[pos + 1] == 0x5D_u8
    i   = pos + 2
    while i < size
      b = ptr[i]
      return i + 1 - pos if osc && b == BEL
      if b == ESC
        return 0 if i + 1 >= size
        return ptr[i + 1] == 0x5C_u8 ? i + 2 - pos : i - pos
      end
      i += 1
    end
    0
  end

  private def dispatch_sequence(span : Bytes) : Nil
    if span.size >= 3 && span.to_unsafe[1] == 0x5B_u8
      dispatch_csi(span)
      return
    end
    return if guarded?(span)
    case span.to_unsafe[1]
    when 0x4F_u8
      final = span.to_unsafe[2]
      apply(Token.new(Token::Kind::Ss3, span, 0_u8, final), @ss3_rules.unsafe_fetch(final))
    when 0x5D_u8
      dispatch_osc(span)
    when 0x50_u8
      dispatch_dcs(span)
    when 0x5F_u8
      apply(Token.new(Token::Kind::Apc, span, 0x5F_u8), @apc_handler || @string_rules.unsafe_fetch(0x5F))
    when 0x5E_u8, 0x58_u8
      intro = span.to_unsafe[1]
      apply(Token.new(Token::Kind::StringSeq, span, intro), @string_rules.unsafe_fetch(intro))
    else
      final = span.to_unsafe[1]
      apply(Token.new(Token::Kind::Escape, span, 0_u8, final), @esc_rules.unsafe_fetch(final))
    end
  end

  private def dispatch_osc(span : Bytes) : Nil
    token   = Token.new(Token::Kind::Osc, span, 0x5D_u8)
    handler = nil.as(Handler?)
    unless @osc_rules.empty?
      if code = token.osc_code
        handler = @osc_rules[code]?
      end
    end
    handler ||= @osc_any
    handler ||= @string_rules.unsafe_fetch(0x5D)
    apply(token, handler)
  end

  private def dispatch_dcs(span : Bytes) : Nil
    final   = dcs_final(span)
    handler = @dcs_rules.unsafe_fetch(final)
    handler ||= @dcs_any
    handler ||= @string_rules.unsafe_fetch(0x50)
    apply(Token.new(Token::Kind::Dcs, span, 0x50_u8, final), handler)
  end

  private def dcs_final(span : Bytes) : UInt8
    ptr  = span.to_unsafe
    size = span.size
    i    = 2
    while i < size && ptr[i] >= 0x30_u8 && ptr[i] <= 0x3F_u8
      i += 1
    end
    while i < size && ptr[i] >= 0x20_u8 && ptr[i] <= 0x2F_u8
      i += 1
    end
    if i < size && ptr[i] >= 0x40_u8 && ptr[i] <= 0x7E_u8
      ptr[i]
    else
      0_u8
    end
  end

  private def dispatch_csi(span : Bytes) : Nil
    final = span.to_unsafe[span.size - 1]
    body  = span[2, span.size - 3]

    marker = 0_u8
    if body.size > 0 && body.to_unsafe[0] >= 0x3C_u8 && body.to_unsafe[0] <= 0x3F_u8
      marker = body.to_unsafe[0]
      body   = body[1, body.size - 1]
    end

    count = parse_params(body)

    if final == 0x7E_u8 && marker == 0_u8 && count == 1
      case @params_buf[0]
      when 200
        @paste = true
        emit_span(span)
        return
      when 201
        @paste = false
        emit_span(span)
        return
      end
    end

    return if guarded?(span)

    token   = Token.new(Token::Kind::Csi, span, marker, final, @params_buf.to_slice[0, count])
    handler = nil.as(Handler?)
    if rules = @csi_rules.unsafe_fetch(final)
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

  private def dispatch_literal(run : Bytes) : Nil
    if @paste
      emit_span(run)
      return
    end

    if @byte_rule_count == 0
      @pass_next = false
      emit_span(run)
    elsif @byte_rule_count <= SCAN_LIST && run.size >= SCAN_MIN
      scan_literal_list(run)
    else
      scan_literal_mask(run)
    end
  end

  private def scan_literal_list(run : Bytes) : Nil
    size  = run.size
    start = 0

    if @pass_next
      @pass_next = false
      emit_span(run[0, 1])
      start = 1
    end

    while start < size
      if size - start < SCAN_MIN
        scan_literal_mask(run[start, size - start])
        return
      end

      idx = next_marked(run, start)
      unless idx
        emit_span(run[start, size - start])
        return
      end

      emit_span(run[start, idx - start]) if idx > start
      apply(Token.new(Token::Kind::Literal, run[idx, 1]), @byte_rules.unsafe_fetch(run.to_unsafe[idx]))
      start = idx + 1

      if @pass_next && start < size
        @pass_next = false
        emit_span(run[start, 1])
        start += 1
      end
    end
  end

  private def next_marked(run : Bytes, from : Int32) : Int32?
    tail = run[from, run.size - from]
    best = -1
    i    = 0
    while i < @byte_list_size
      if idx = tail.index(@byte_list.unsafe_fetch(i))
        return from if idx == 0
        best = idx if best < 0 || idx < best
      end
      i += 1
    end
    best < 0 ? nil : from + best
  end

  private def scan_literal_mask(run : Bytes) : Nil
    ptr   = run.to_unsafe
    size  = run.size
    start = 0

    if @pass_next
      @pass_next = false
      emit_span(run[0, 1])
      start = 1
    end

    i = start
    while i < size
      while i < size && !marked?(ptr[i])
        i += 1
      end
      break if i >= size

      emit_span(run[start, i - start]) if i > start
      apply(Token.new(Token::Kind::Literal, run[i, 1]), @byte_rules.unsafe_fetch(ptr[i]))
      i += 1
      start = i

      if @pass_next && i < size
        @pass_next = false
        emit_span(run[i, 1])
        i += 1
        start = i
      end
    end

    emit_span(run[start, size - start]) if start < size
  end

  private def marked?(byte : UInt8) : Bool
    @byte_mask.unsafe_fetch(byte >> 6) & (1_u64 << (byte & 0x3F_u8)) != 0
  end

  private def mark(byte : UInt8) : Nil
    @byte_mask[byte >> 6] |= 1_u64 << (byte & 0x3F_u8)
  end

  private def add_csi(final : UInt8, marker : UInt8?, params : Slice(Int32), handler : Handler) : Nil
    rules = @csi_rules[final]
    unless rules
      rules = [] of CsiRule
      @csi_rules[final] = rules
    end
    rules << CsiRule.new(marker, params, handler)
  end

  private def guarded?(span : Bytes) : Bool
    if @paste
      emit_span(span)
      return true
    end
    if @pass_next
      @pass_next = false
      emit_span(span)
      return true
    end
    false
  end

  private def apply(token : Token, handler : Handler?) : Nil
    unless handler
      emit_span(token.bytes)
      return
    end
    disposition = handler.call(token)
    case disposition.kind
    in Disposition::Kind::Pass    then emit_span(token.bytes)
    in Disposition::Kind::Drop    then materialize
    in Disposition::Kind::Replace then emit_foreign(disposition.bytes)
    end
  end

  private def emit_span(bytes : Bytes) : Nil
    return if bytes.empty?
    if @copying
      append_out(bytes)
    else
      @passed += bytes.size
    end
  end

  private def emit_foreign(bytes : Bytes) : Nil
    materialize
    append_out(bytes)
  end

  private def materialize : Nil
    return if @copying
    @copying = true
    append_out(@src[0, @passed]) if @passed > 0
  end

  private def ensure_carry(size : Int32) : Nil
    return if size <= @carry.size
    @carry = Buffer.grow(@carry, size, 0)
  end

  private def append_carry(chunk : Bytes) : Nil
    needed = @carry_size + chunk.size
    if @carry_off + needed > @carry.size
      if needed > @carry.size
        grown = Buffer.grow(@carry, needed, 0)
        (@carry.to_unsafe + @carry_off).copy_to(grown.to_unsafe, @carry_size)
        @carry = grown
      elsif @carry_size > 0
        (@carry.to_unsafe + @carry_off).move_to(@carry.to_unsafe, @carry_size)
      end
      @carry_off = 0
    end
    chunk.copy_to(@carry.to_unsafe + @carry_off + @carry_size, chunk.size)
    @carry_size = needed
  end

  private def append_out(bytes : Bytes) : Nil
    return if bytes.empty?
    needed = @out_size + bytes.size
    @out   = Buffer.grow(@out, needed, @out_size) if needed > @out.size
    bytes.copy_to(@out.to_unsafe + @out_size, bytes.size)
    @out_size = needed
  end
end

class Term::Mux::OutputFilter
  alias Handler = Token -> Disposition

  ESC = 0x1B_u8
  BEL = 0x07_u8

  MAX_CARRY  = 8192
  MAX_PARAMS =   16
  TABLE      =  256
  SCAN_LIST  =    4
  SCAN_MIN   =   32

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

  @src        : Bytes = Bytes.empty
  @carry      : Bytes
  @carry_off  : Int32 = 0
  @carry_size : Int32 = 0
  @out        : Bytes
  @out_size   : Int32 = 0
  @copying    : Bool  = false
  @passed     : Int32 = 0

  @byte_rules      : Array(Handler?)
  @byte_mask       : StaticArray(UInt64, 4)
  @byte_list       : StaticArray(UInt8, SCAN_LIST)
  @byte_list_size  : Int32 = 0
  @byte_rule_count : Int32 = 0

  @csi_rules    : Array(Array(CsiRule)?)
  @ss3_rules    : Array(Handler?)
  @esc_rules    : Array(Handler?)
  @string_rules : Array(Handler?)
  @dcs_rules    : Array(Handler?)
  @osc_rules    : Hash(Int32, Handler)
  @osc_any      : Handler? = nil
  @dcs_any      : Handler? = nil
  @apc_handler  : Handler? = nil

  @params_buf : StaticArray(Int32, MAX_PARAMS)

  def initialize
    @carry        = Buffer.alloc(1024)
    @out          = Buffer.alloc(4096)
    @byte_rules   = Array(Handler?).new(TABLE, nil)
    @csi_rules    = Array(Array(CsiRule)?).new(TABLE, nil)
    @ss3_rules    = Array(Handler?).new(TABLE, nil)
    @esc_rules    = Array(Handler?).new(TABLE, nil)
    @string_rules = Array(Handler?).new(TABLE, nil)
    @dcs_rules    = Array(Handler?).new(TABLE, nil)
    @osc_rules    = Hash(Int32, Handler).new
    @byte_mask    = StaticArray(UInt64, 4).new(0_u64)
    @byte_list = uninitialized StaticArray(UInt8, SCAN_LIST)
    @params_buf = uninitialized StaticArray(Int32, MAX_PARAMS)
  end

  def on(seq : Sequence, &handler : Handler) : self
    add_csi(seq.final, seq.marker == 0_u8 ? nil : seq.marker, seq.params, handler)
    self
  end

  def on(pair : ModePair, &handler : Handler) : self
    on(pair.set, &handler)
    on(pair.reset, &handler)
  end

  def on_byte(byte : UInt8, &handler : Handler) : self
    unless marked?(byte)
      mark(byte)
      @byte_rule_count += 1
      if @byte_list_size < SCAN_LIST
        @byte_list[@byte_list_size] = byte
        @byte_list_size += 1
      end
    end
    @byte_rules[byte] = handler
    self
  end

  def on_byte(char : Char, &handler : Handler) : self
    on_byte(char.ord.to_u8, &handler)
  end

  def on_csi(final : Char, marker : Char? = nil, params : Array(Int32) = [] of Int32, &handler : Handler) : self
    slice = Slice(Int32).new(params.size) { |i| params[i] }
    add_csi(final.ord.to_u8, marker.try(&.ord.to_u8), slice, handler)
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

  def feed(chunk : Bytes) : Bytes
    return Bytes.empty if chunk.empty?
    if @carry_size == 0
      @carry_off = 0
      return chunk if !chunk.index(ESC) && @byte_rule_count == 0
      return feed_direct(chunk)
    end
    feed_carried(chunk)
  end

  private def feed_direct(chunk : Bytes) : Bytes
    @src      = chunk
    @copying  = false
    @passed   = 0
    @out_size = 0

    pos       = scan(chunk)
    remaining = chunk.size - pos

    if remaining > MAX_CARRY
      emit_span(chunk[pos, remaining])
      remaining = 0
    end

    if remaining > 0
      ensure_carry(remaining)
      chunk[pos, remaining].copy_to(@carry.to_unsafe, remaining)
      @carry_off  = 0
      @carry_size = remaining
    end

    result = @copying ? @out[0, @out_size] : chunk[0, @passed]
    @src   = Bytes.empty
    result
  end

  private def feed_carried(chunk : Bytes) : Bytes
    append_carry(chunk)

    src       = @carry[@carry_off, @carry_size]
    @src      = src
    @copying  = false
    @passed   = 0
    @out_size = 0

    pos       = scan(src)
    remaining = @carry_size - pos

    if remaining > MAX_CARRY
      emit_span(src[pos, remaining])
      pos += remaining
      remaining = 0
    end

    @carry_off += pos
    @carry_size = remaining

    result = @copying ? @out[0, @out_size] : src[0, @passed]
    @src   = Bytes.empty
    result
  end

  private def scan(src : Bytes) : Int32
    pos  = 0
    size = src.size
    while pos < size
      if src.to_unsafe[pos] == ESC
        len = sequence_length(src, pos, size)
        break if len == 0
        dispatch_sequence(src[pos, len])
        pos += len
      else
        stop = literal_end(src, pos, size)
        dispatch_literal(src[pos, stop - pos])
        pos = stop
      end
    end
    pos
  end

  private def literal_end(src : Bytes, pos : Int32, size : Int32) : Int32
    idx = src[pos, size - pos].index(ESC)
    idx ? pos + idx : size
  end

  private def sequence_length(src : Bytes, pos : Int32, size : Int32) : Int32
    return 0 if pos + 1 >= size
    ptr = src.to_unsafe
    case ptr[pos + 1]
    when 0x5B_u8
      i = pos + 2
      while i < size && ptr[i] >= 0x30_u8 && ptr[i] <= 0x3F_u8
        i += 1
      end
      while i < size && ptr[i] >= 0x20_u8 && ptr[i] <= 0x2F_u8
        i += 1
      end
      return 0 if i >= size
      (ptr[i] >= 0x40_u8 && ptr[i] <= 0x7E_u8) ? i + 1 - pos : 2
    when 0x4F_u8
      pos + 2 < size ? 3 : 0
    when 0x5D_u8, 0x50_u8, 0x5E_u8, 0x5F_u8, 0x58_u8
      string_length(src, pos, size)
    else
      2
    end
  end

  private def string_length(src : Bytes, pos : Int32, size : Int32) : Int32
    ptr = src.to_unsafe
    osc = ptr[pos + 1] == 0x5D_u8
    i   = pos + 2
    while i < size
      b = ptr[i]
      return i + 1 - pos if osc && b == BEL
      if b == ESC
        return 0 if i + 1 >= size
        return ptr[i + 1] == 0x5C_u8 ? i + 2 - pos : i - pos
      end
      i += 1
    end
    0
  end

  private def dispatch_sequence(span : Bytes) : Nil
    if span.size >= 3 && span.to_unsafe[1] == 0x5B_u8
      dispatch_csi(span)
      return
    end
    case span.to_unsafe[1]
    when 0x4F_u8
      final = span.to_unsafe[2]
      apply(Token.new(Token::Kind::Ss3, span, 0_u8, final), @ss3_rules.unsafe_fetch(final))
    when 0x5D_u8
      dispatch_osc(span)
    when 0x50_u8
      dispatch_dcs(span)
    when 0x5F_u8
      apply(Token.new(Token::Kind::Apc, span, 0x5F_u8), @apc_handler || @string_rules.unsafe_fetch(0x5F))
    when 0x5E_u8, 0x58_u8
      intro = span.to_unsafe[1]
      apply(Token.new(Token::Kind::StringSeq, span, intro), @string_rules.unsafe_fetch(intro))
    else
      final = span.to_unsafe[1]
      apply(Token.new(Token::Kind::Escape, span, 0_u8, final), @esc_rules.unsafe_fetch(final))
    end
  end

  private def dispatch_osc(span : Bytes) : Nil
    token   = Token.new(Token::Kind::Osc, span, 0x5D_u8)
    handler = nil.as(Handler?)
    unless @osc_rules.empty?
      if code = token.osc_code
        handler = @osc_rules[code]?
      end
    end
    handler ||= @osc_any
    handler ||= @string_rules.unsafe_fetch(0x5D)
    apply(token, handler)
  end

  private def dispatch_dcs(span : Bytes) : Nil
    final   = dcs_final(span)
    handler = @dcs_rules.unsafe_fetch(final)
    handler ||= @dcs_any
    handler ||= @string_rules.unsafe_fetch(0x50)
    apply(Token.new(Token::Kind::Dcs, span, 0x50_u8, final), handler)
  end

  private def dcs_final(span : Bytes) : UInt8
    ptr  = span.to_unsafe
    size = span.size
    i    = 2
    while i < size && ptr[i] >= 0x30_u8 && ptr[i] <= 0x3F_u8
      i += 1
    end
    while i < size && ptr[i] >= 0x20_u8 && ptr[i] <= 0x2F_u8
      i += 1
    end
    if i < size && ptr[i] >= 0x40_u8 && ptr[i] <= 0x7E_u8
      ptr[i]
    else
      0_u8
    end
  end

  private def dispatch_csi(span : Bytes) : Nil
    final = span.to_unsafe[span.size - 1]
    body  = span[2, span.size - 3]

    marker = 0_u8
    if body.size > 0 && body.to_unsafe[0] >= 0x3C_u8 && body.to_unsafe[0] <= 0x3F_u8
      marker = body.to_unsafe[0]
      body   = body[1, body.size - 1]
    end

    count = parse_params(body)

    token   = Token.new(Token::Kind::Csi, span, marker, final, @params_buf.to_slice[0, count])
    handler = nil.as(Handler?)
    if rules = @csi_rules.unsafe_fetch(final)
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

  private def dispatch_literal(run : Bytes) : Nil
    if @byte_rule_count == 0
      emit_span(run)
    elsif @byte_rule_count <= SCAN_LIST && run.size >= SCAN_MIN
      scan_literal_list(run)
    else
      scan_literal_mask(run)
    end
  end

  private def scan_literal_list(run : Bytes) : Nil
    size  = run.size
    start = 0
    while start < size
      if size - start < SCAN_MIN
        scan_literal_mask(run[start, size - start])
        return
      end

      idx = next_marked(run, start)
      unless idx
        emit_span(run[start, size - start])
        return
      end

      emit_span(run[start, idx - start]) if idx > start
      apply(Token.new(Token::Kind::Literal, run[idx, 1]), @byte_rules.unsafe_fetch(run.to_unsafe[idx]))
      start = idx + 1
    end
  end

  private def next_marked(run : Bytes, from : Int32) : Int32?
    tail = run[from, run.size - from]
    best = -1
    i    = 0
    while i < @byte_list_size
      if idx = tail.index(@byte_list.unsafe_fetch(i))
        return from if idx == 0
        best = idx if best < 0 || idx < best
      end
      i += 1
    end
    best < 0 ? nil : from + best
  end

  private def scan_literal_mask(run : Bytes) : Nil
    ptr   = run.to_unsafe
    size  = run.size
    start = 0
    i     = 0
    while i < size
      while i < size && !marked?(ptr[i])
        i += 1
      end
      break if i >= size

      emit_span(run[start, i - start]) if i > start
      apply(Token.new(Token::Kind::Literal, run[i, 1]), @byte_rules.unsafe_fetch(ptr[i]))
      i += 1
      start = i
    end
    emit_span(run[start, size - start]) if start < size
  end

  private def marked?(byte : UInt8) : Bool
    @byte_mask.unsafe_fetch(byte >> 6) & (1_u64 << (byte & 0x3F_u8)) != 0
  end

  private def mark(byte : UInt8) : Nil
    @byte_mask[byte >> 6] |= 1_u64 << (byte & 0x3F_u8)
  end

  private def add_csi(final : UInt8, marker : UInt8?, params : Slice(Int32), handler : Handler) : Nil
    rules = @csi_rules[final]
    unless rules
      rules = [] of CsiRule
      @csi_rules[final] = rules
    end
    rules << CsiRule.new(marker, params, handler)
  end

  private def apply(token : Token, handler : Handler?) : Nil
    unless handler
      emit_span(token.bytes)
      return
    end
    disposition = handler.call(token)
    case disposition.kind
    in Disposition::Kind::Pass    then emit_span(token.bytes)
    in Disposition::Kind::Drop    then materialize
    in Disposition::Kind::Replace then emit_foreign(disposition.bytes)
    end
  end

  private def emit_span(bytes : Bytes) : Nil
    return if bytes.empty?
    if @copying
      append_out(bytes)
    else
      @passed += bytes.size
    end
  end

  private def emit_foreign(bytes : Bytes) : Nil
    materialize
    append_out(bytes)
  end

  private def materialize : Nil
    return if @copying
    @copying = true
    append_out(@src[0, @passed]) if @passed > 0
  end

  private def ensure_carry(size : Int32) : Nil
    return if size <= @carry.size
    @carry = Buffer.grow(@carry, size, 0)
  end

  private def append_carry(chunk : Bytes) : Nil
    needed = @carry_size + chunk.size
    if @carry_off + needed > @carry.size
      if needed > @carry.size
        grown = Buffer.grow(@carry, needed, 0)
        (@carry.to_unsafe + @carry_off).copy_to(grown.to_unsafe, @carry_size)
        @carry = grown
      elsif @carry_size > 0
        (@carry.to_unsafe + @carry_off).move_to(@carry.to_unsafe, @carry_size)
      end
      @carry_off = 0
    end
    chunk.copy_to(@carry.to_unsafe + @carry_off + @carry_size, chunk.size)
    @carry_size = needed
  end

  private def append_out(bytes : Bytes) : Nil
    return if bytes.empty?
    needed = @out_size + bytes.size
    @out   = Buffer.grow(@out, needed, @out_size) if needed > @out.size
    bytes.copy_to(@out.to_unsafe + @out_size, bytes.size)
    @out_size = needed
  end
end
