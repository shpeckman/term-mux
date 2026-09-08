# src/mux/emitter.cr
class Term::Mux::Emitter
  OSC_INTRO = "\e]".to_slice
  ST        = "\e\\".to_slice

  BEL        = 0x07_u8
  SEMI       = 0x3B_u8
  ZERO       = 0x30_u8
  MAX_DIGITS =      10

  enum StringTerminator : UInt8
    Bel
    St
  end

  property string_terminator : StringTerminator
  getter size                : Int32 = 0

  @buf : Bytes

  def initialize(capacity : Int32 = 4096, @string_terminator : StringTerminator = StringTerminator::St)
    @buf = Buffer.alloc(capacity)
  end

  def empty? : Bool
    @size == 0
  end

  def bytes : Bytes
    @buf[0, @size]
  end

  def take : Bytes
    span  = @buf[0, @size]
    @size = 0
    span
  end

  def reset : self
    @size = 0
    self
  end

  def raw(bytes : Bytes) : self
    append(bytes)
    self
  end

  def raw(str : String) : self
    append(str.to_slice)
    self
  end

  def text(str : String) : self
    append(str.to_slice)
    self
  end

  def <<(bytes : Bytes) : self
    raw(bytes)
  end

  def <<(str : String) : self
    raw(str)
  end

  def byte(value : UInt8) : self
    reserve(1)
    @buf.to_unsafe[@size] = value
    @size += 1
    self
  end

  def num(value : Int32) : self
    reserve(MAX_DIGITS)
    @size = write_num(@buf.to_unsafe, @size, value)
    self
  end

  def mode(pair : ModePair, on : Bool) : self
    raw(pair.bytes(on))
  end

  def mode(pair : ModePair, &) : self
    raw(pair.set_bytes)
    yield
    raw(pair.reset_bytes)
  end

  protected def emit_csi(intro : Bytes, values : Slice(Int32), defaults : Slice(Int32), final : UInt8) : self
    reserve(intro.size + values.size * (MAX_DIGITS + 1) + 1)

    dst = @buf.to_unsafe
    at  = @size

    intro.copy_to(dst + at, intro.size)
    at += intro.size

    last = -1
    i    = 0
    while i < values.size
      last = i unless i < defaults.size && values[i] == defaults[i]
      i += 1
    end

    i = 0
    while i <= last
      if i > 0
        dst[at] = SEMI
        at += 1
      end
      unless i < defaults.size && values[i] == defaults[i]
        at = write_num(dst, at, values[i])
      end
      i += 1
    end

    dst[at] = final
    @size = at + 1
    self
  end

  protected def emit_osc(code : Int32, payload : String) : self
    body = payload.to_slice
    reserve(OSC_INTRO.size + MAX_DIGITS + 1 + body.size + ST.size)

    dst = @buf.to_unsafe
    at  = @size

    OSC_INTRO.copy_to(dst + at, OSC_INTRO.size)
    at += OSC_INTRO.size

    at = write_num(dst, at, code)

    dst[at] = SEMI
    at += 1

    body.copy_to(dst + at, body.size)
    at += body.size

    case @string_terminator
    in StringTerminator::Bel
      dst[at] = BEL
      at += 1
    in StringTerminator::St
      ST.copy_to(dst + at, ST.size)
      at += ST.size
    end

    @size = at
    self
  end

  private def write_num(dst : UInt8*, at : Int32, value : Int32) : Int32
    if value <= 0
      dst[at] = ZERO
      return at + 1
    end
    count = digit_count(value)
    i     = at + count
    v     = value
    while v > 0
      i -= 1
      dst[i] = ZERO + (v % 10).to_u8
      v //= 10
    end
    at + count
  end

  private def digit_count(value : Int32) : Int32
    return 1 if value < 10
    return 2 if value < 100
    return 3 if value < 1_000
    return 4 if value < 10_000
    return 5 if value < 100_000
    return 6 if value < 1_000_000
    return 7 if value < 10_000_000
    return 8 if value < 100_000_000
    return 9 if value < 1_000_000_000
    10
  end

  private def reserve(extra : Int32) : Nil
    needed = @size + extra
    return if needed <= @buf.size
    @buf = Buffer.grow(@buf, needed, @size)
  end

  private def append(src : Bytes) : Nil
    return if src.empty?
    reserve(src.size)
    src.copy_to(@buf.to_unsafe + @size, src.size)
    @size += src.size
  end

  macro define(&block)
      {% body = block.body %}
      {% exps = body.is_a?(Expressions) ? body.expressions : [body] %}

      {% for exp in exps %}
        {% kind = exp.name.stringify %}
        {% decl = exp.args[0] %}
        {% mname = decl.is_a?(Call) ? decl.name : decl.id %}
        {% dargs = decl.is_a?(Call) ? decl.args : [] of ASTNode %}
        {% const = mname.stringify.upcase.id %}

        {% opts = {} of String => ASTNode %}
        {% if exp.named_args %}
          {% for na in exp.named_args %}
            {% opts[na.name.stringify] = na.value %}
          {% end %}
        {% end %}

        {% if kind == "raw" %}
          class ::Term::Mux::Emitter
            {{const}} = {{exp.args[1]}}.to_slice

            def {{mname}} : self
              raw({{const}})
            end
          end

        {% elsif kind == "decset" %}
          {% dmode = opts["mode"] %}

          module ::Term::Mux::Sequences
            {{const}} = ::Term::Mux::ModePair.new(
              {{dmode}},
              ::Term::Mux::Sequence.new(0x3F_u8, 0x68_u8, Slice[{{dmode}}]),
              ::Term::Mux::Sequence.new(0x3F_u8, 0x6C_u8, Slice[{{dmode}}]),
              "\e[?{{dmode.id}}h".to_slice,
              "\e[?{{dmode.id}}l".to_slice,
            )
          end

          class ::Term::Mux::Emitter
            def {{mname}}(on : Bool) : self
              mode(::Term::Mux::Sequences::{{const}}, on)
            end

            {% if opts["block"] %}
            def {{mname}}(&) : self
              raw(::Term::Mux::Sequences::{{const}}.set_bytes)
              yield
              raw(::Term::Mux::Sequences::{{const}}.reset_bytes)
            end
            {% end %}
          end

        {% elsif kind == "csi" %}
          {% final = opts["final"] %}
          {% marker = opts["marker"] %}

          {% if dargs.empty? %}
            {% cparams = opts["params"] %}
            {% pstr = cparams ? cparams.map(&.stringify).join(";") : "" %}

            class ::Term::Mux::Emitter
              {{const}} = "\e[{% if marker %}{{marker.id}}{% end %}{{pstr.id}}{{final.id}}".to_slice

              def {{mname}} : self
                raw({{const}})
              end
            end

            module ::Term::Mux::Sequences
              {{const}} = ::Term::Mux::Sequence.new(
                {% if marker %}{{marker}}.ord.to_u8{% else %}0_u8{% end %},
                {{final}}.ord.to_u8,
                {% if cparams %}Slice[{{cparams.splat}}]{% else %}Slice(Int32).empty{% end %})
            end

          {% else %}
            {% cdefaults = opts["defaults"] %}

            class ::Term::Mux::Emitter
              {{const}}_INTRO    = "\e[{% if marker %}{{marker.id}}{% end %}".to_slice
              {{const}}_DEFAULTS = {% if cdefaults %}Slice[{{cdefaults.splat}}]{% else %}Slice(Int32).empty{% end %}
              {{const}}_FINAL    = {{final}}.ord.to_u8

              def {{mname}}({{ dargs.map { |a| "#{a.id} : Int32".id }.splat }}) : self
                values = StaticArray[{{dargs.splat}}]
                emit_csi({{const}}_INTRO, values.to_slice, {{const}}_DEFAULTS, {{const}}_FINAL)
              end
            end

            module ::Term::Mux::Sequences
              {{const}} = ::Term::Mux::Sequence.new(
                {% if marker %}{{marker}}.ord.to_u8{% else %}0_u8{% end %},
                {{final}}.ord.to_u8)
            end
          {% end %}

        {% elsif kind == "osc" %}
          {% pname = dargs.empty? ? "text".id : dargs[0].id %}

          class ::Term::Mux::Emitter
            {{const}}_CODE = {{opts["code"]}}

            def {{mname}}({{pname}} : String) : self
              emit_osc({{const}}_CODE, {{pname}})
            end
          end
        {% end %}
      {% end %}
    end
end
