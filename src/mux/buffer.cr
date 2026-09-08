# src/mux/buffer.cr
module Term::Mux::Buffer
  MIN = 64

  def self.alloc(size : Int32) : Bytes
    return Bytes.empty if size <= 0
    Bytes.new(GC.malloc_atomic(LibC::SizeT.new(size)).as(UInt8*), size)
  end

  def self.grow(current : Bytes, needed : Int32, used : Int32) : Bytes
    cap = current.size
    cap = MIN if cap < MIN
    while cap < needed
      cap *= 2
    end
    grown = alloc(cap)
    current.to_unsafe.copy_to(grown.to_unsafe, used) if used > 0
    grown
  end
end
