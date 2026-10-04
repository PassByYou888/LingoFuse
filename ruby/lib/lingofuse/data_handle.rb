# frozen_string_literal: true
#
# data_handle.rb — RAII wrapper around a native LingoFuse data handle.
#
# Uses Ruby's standard-library Fiddle (not the FFI gem). Every native
# call goes through a Fiddle::Function created in binding.rb.
#
# ============================================================================
# TWO KINDS OF HANDLES
# ============================================================================
#   Auto-recycled  (DataHandle.new)             LF_CreateData
#   Permanent      (DataHandle.create_permanent) LF_CreateData_Permanent
#
# Both must be explicitly disposed. The auto-recycler (10-minute idle,
# 5-second scan) is a safety net, not a substitute for dispose.
#
# ============================================================================
# OWNERSHIP
# ============================================================================
#   Owning    — dispose calls LF_FreeData
#   Borrowing — dispose is a no-op (used inside callbacks)
#
# ============================================================================
# STRING CONTRACT
# ============================================================================
# LingoFuse frames strings with a single trailing NUL byte. write_string
# always appends the terminator. read_string is fault-tolerant: it reads
# until the first NUL, or all remaining bytes when no NUL is present.
# Invalid UTF-8 sequences become U+FFFD via String#scrub.
#
# ============================================================================
# POINTER NULLITY
# ============================================================================
# Fiddle returns TYPE_VOIDP results as Fiddle::Pointer or as Integer 0.
# Use null_ptr? to test both cases.
#

require 'fiddle'

require_relative 'binding'
require_relative 'errors'

module LingoFuse
  class DataHandle
    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    def self.new(api_name)
      allocate.tap { |o| o.send(:initialize_internal, api_name, true, :auto) }
    end

    def self.create_permanent(api_name)
      allocate.tap { |o| o.send(:initialize_internal, api_name, true, :permanent) }
    end

    def self.from_raw(raw, owned)
      allocate.tap do |o|
        o.instance_variable_set(:@handle, raw)
        o.instance_variable_set(:@owned, !!owned)
        o.instance_variable_set(:@disposed, false)
        o.instance_variable_set(:@api_name, nil)
        o.instance_variable_set(:@kind, owned ? :from_raw : :borrowed)
      end
    end

    def self.borrow(raw)
      from_raw(raw, false)
    end

    def self.open(api_name)
      handle = new(api_name)
      return handle unless block_given?
      begin
        yield handle
      ensure
        handle.dispose
      end
    end

    def initialize_internal(api_name, owned, kind)
      name_s = api_name.to_s
      @api_name = name_s
      @owned = !!owned
      @disposed = false
      @kind = kind

      name_ptr = LingoFuse.cstr_ptr(name_s)
      raw =
        if kind == :permanent
          LingoFuse::LF_CreateData_Permanent.call(name_ptr)
        else
          LingoFuse::LF_CreateData.call(name_ptr)
        end

      if null_ptr?(raw)
        raise Error, "Failed to create a data handle for API '#{name_s}'."
      end
      @handle = raw
    end
    private :initialize_internal

    def initialize(*)
      raise Error, 'DataHandle must be created through new, ' \
                   'create_permanent, from_raw, borrow, or open.'
    end
    private :initialize

    # ------------------------------------------------------------------
    # Identity and state
    # ------------------------------------------------------------------

    def raw; @handle; end

    def valid?
      !@disposed && !null_ptr?(@handle)
    end

    def owning?; @owned; end
    def api_name; @api_name; end

    # ------------------------------------------------------------------
    # Lifetime
    # ------------------------------------------------------------------

    def dispose
      return if @disposed
      return unless @owned
      @disposed = true
      handle = @handle
      @handle = nil
      LingoFuse::LF_FreeData.call(handle) unless null_ptr?(handle)
      nil
    end
    alias close dispose

    # ------------------------------------------------------------------
    # Position and size
    # ------------------------------------------------------------------

    def position
      ensure_not_disposed!
      LingoFuse::LF_GetPos.call(@handle)
    end

    def position=(value)
      ensure_not_disposed!
      v = Integer(value)
      raise ArgumentError, 'position must be non-negative' if v.negative?
      LingoFuse::LF_SetPos.call(@handle, v)
      nil
    end

    def size
      ensure_not_disposed!
      LingoFuse::LF_GetSize.call(@handle)
    end

    def size=(value)
      ensure_not_disposed!
      v = Integer(value)
      raise ArgumentError, 'size must be non-negative' if v.negative?
      LingoFuse::LF_SetSize.call(@handle, v)
      nil
    end

    def get_buffer_pointer
      ensure_not_disposed!
      LingoFuse::LF_GetBuffer.call(@handle)
    end

    # ------------------------------------------------------------------
    # Byte I/O
    # ------------------------------------------------------------------

    def write_bytes(data)
      ensure_not_disposed!
      return 0 if data.nil?
      s = data.is_a?(String) ? data.b : data.to_s.b
      return 0 if s.empty?

      count = s.bytesize
      buf = Fiddle::Pointer.malloc(count)
      buf[0, count] = s
      written = LingoFuse::LF_WriteBuffer.call(@handle, buf, count)

      if written != count
        raise IoError.new(
          "write_bytes requested #{count} bytes but only #{written} written.",
          operation: 'write_bytes'
        )
      end
      written
    end

    def read_bytes(count)
      ensure_not_disposed!
      c = Integer(count)
      return ''.b if c <= 0

      buf = Fiddle::Pointer.malloc(c)
      got = LingoFuse::LF_ReadBuffer.call(@handle, buf, c)
      return ''.b if got.nil? || got <= 0
      buf[0, got]
    end

    def read_bytes_exact(count)
      ensure_not_disposed!
      c = Integer(count)
      raise ArgumentError, 'count must be non-negative' if c.negative?
      return ''.b if c.zero?

      saved = position
      buf = read_bytes(c)
      if buf.bytesize != c
        self.position = saved
        raise IoError.new(
          "read_bytes_exact requested #{c} bytes, only #{buf.bytesize} available.",
          operation: 'read_bytes_exact'
        )
      end
      buf
    end

    def try_read_bytes(count)
      ensure_not_disposed!
      c = Integer(count)
      raise ArgumentError, 'count must be non-negative' if c.negative?
      return ''.b if c.zero?

      saved = position
      buf = read_bytes(c)
      if buf.bytesize != c
        self.position = saved
        return nil
      end
      buf
    end

    def read_all_bytes
      ensure_not_disposed!
      pos = position
      total = size
      return ''.b if pos >= total
      read_bytes(total - pos)
    end

    # ------------------------------------------------------------------
    # Scalar I/O (little-endian)
    # ------------------------------------------------------------------

    def write_int8(v);  write_bytes([Integer(v)].pack('c'))  == 1; end
    def write_uint8(v); write_bytes([Integer(v)].pack('C'))  == 1; end
    def write_int16(v); write_bytes([Integer(v)].pack('s<')) == 2; end
    def write_uint16(v); write_bytes([Integer(v)].pack('S<')) == 2; end
    def write_int32(v); write_bytes([Integer(v)].pack('l<')) == 4; end
    def write_uint32(v); write_bytes([Integer(v)].pack('L<')) == 4; end
    def write_int64(v); write_bytes([Integer(v)].pack('q<')) == 8; end
    def write_uint64(v); write_bytes([Integer(v)].pack('Q<')) == 8; end
    def write_single(v); write_bytes([Float(v)].pack('e')) == 4; end
    def write_double(v); write_bytes([Float(v)].pack('E')) == 8; end

    def read_int8;   read_bytes_exact(1).unpack1('c');  end
    def read_uint8;  read_bytes_exact(1).unpack1('C');  end
    def read_int16;  read_bytes_exact(2).unpack1('s<'); end
    def read_uint16; read_bytes_exact(2).unpack1('S<'); end
    def read_int32;  read_bytes_exact(4).unpack1('l<'); end
    def read_uint32; read_bytes_exact(4).unpack1('L<'); end
    def read_int64;  read_bytes_exact(8).unpack1('q<'); end
    def read_uint64; read_bytes_exact(8).unpack1('Q<'); end
    def read_single; read_bytes_exact(4).unpack1('e');  end
    def read_double; read_bytes_exact(8).unpack1('E');  end

    # ------------------------------------------------------------------
    # NUL-framed string I/O
    # ------------------------------------------------------------------

    def write_string(value)
      ensure_not_disposed!
      encoded = value.to_s.encode('UTF-8')
      write_bytes(encoded + "\x00".b)
      true
    end

    def read_string
      ensure_not_disposed!
      raw = read_until_nul
      return '' if raw.empty?
      raw.force_encoding('UTF-8').scrub
    end

    def read_string_bytes
      ensure_not_disposed!
      read_until_nul
    end

    def try_read_string
      ensure_not_disposed!
      return nil if position >= size
      read_string
    end

    # ------------------------------------------------------------------
    # Private
    # ------------------------------------------------------------------

    private

    def null_ptr?(p)
      p.nil? || (p.respond_to?(:to_i) && p.to_i.zero?)
    end

    def ensure_not_disposed!
      return unless @disposed || null_ptr?(@handle)
      raise ObjectDisposedError.new('DataHandle')
    end

    # Reads bytes up to the first NUL (or the end of the buffer), and
    # advances the cursor past the NUL (or to size + 1 when no NUL was
    # found). See the class header for the three-case rule.
    def read_until_nul
      pos = position
      total = size
      return ''.b if pos >= total

      base = LingoFuse::LF_GetBuffer.call(@handle)
      return ''.b if null_ptr?(base)

      ptr = Fiddle::Pointer.new(base)
      end_pos = pos
      end_pos += 1 while end_pos < total && ptr[end_pos] != 0

      length = end_pos - pos
      raw =
        if length.zero?
          ''.b
        else
          buf = Fiddle::Pointer.malloc(length)
          got = LingoFuse::LF_ReadBuffer.call(@handle, buf, length)
          if got != length
            raise IoError.new(
              "read_until_nul: short read (#{got} of #{length})",
              operation: 'read_until_nul'
            )
          end
          buf[0, length]
        end

      if end_pos < total
        self.position = end_pos + 1
      else
        self.position = total + 1
      end

      raw
    end
  end
end