# frozen_string_literal: true
#
# lf_io.rb — Unified JSON, string, and byte I/O for LingoFuse data handles.
#
# ============================================================================
# WHY THIS FILE EXISTS
# ============================================================================
# This module is the SINGLE place in the Ruby binding where structured
# values are converted to and from the bytes carried by a LingoFuse
# DataHandle. Every service that touches a DataHandle must go through
# the helpers defined here instead of calling DataHandle#write_json /
# DataHandle#read_json, JSON.generate, or JSON.parse directly.
#
# The same policy is implemented, with byte-for-byte identical output,
# in every other LingoFuse binding:
#
#     - lf_io.hpp        (C++)
#     - LfIo.cs          (C#)
#     - lf-io.js         (JavaScript)
#     - io.rs            (Rust)
#     - lf_io.py         (Python)
#     - LfIo.swift       (Swift)
#
# ============================================================================
# WIRE FORMAT
# ============================================================================
# A JSON payload on a data handle is:
#
#     [UTF-8 encoded JSON text][NUL byte]
#
# A plain-text payload uses the same framing:
#
#     [UTF-8 text][NUL byte]
#
# A raw binary payload uses:
#
#     [arbitrary bytes][NUL byte]
#
# The receiving side (read_string / read_string_bytes / read_json) is
# fault-tolerant: if no NUL is found before the end of the buffer, the
# entire remaining buffer is consumed. This makes the reader tolerant of
# payloads that arrive from an HTTP bridge or any other producer that
# does not append a NUL.
#
# ============================================================================
# CROSS-LANGUAGE COMPATIBILITY
# ============================================================================
# The framing matches the reference Pascal implementation exactly. For
# the logical payload {"a":1}, every binding emits the byte sequence
#
#     7B 22 61 22 3A 31 7D 00
#
# and every reader follows the same three-case rule:
#
#     Case 1 — a NUL is found:
#         Return the bytes before it, advance the cursor past the NUL.
#
#     Case 2 — no NUL is found:
#         Return the entire remaining buffer, advance the cursor to
#         (buffer size + 1). The underlying library implicitly grows the
#         buffer by one byte to accommodate the new position. This
#         matches Pascal's LF_SetPos(Hnd, e + 1) with e == size.
#
#     Case 3 — the cursor is at or past the end:
#         Return an empty result, cursor unchanged.
#
# ============================================================================
# JSON SERIALIZATION POLICY
# ============================================================================
# Every JSON string produced by this module goes through `dumps_json`.
# That function is the single source of truth for the serialization
# policy. Its three properties are:
#
#   - Compact output: no indentation, no trailing newline.
#     `JSON.generate` already produces this.
#
#   - `ascii_only: false`: non-ASCII characters are emitted as literal
#     UTF-8, not as `\uXXXX` escapes. This matches the Python
#     (ensure_ascii=False), C++ (error_handler_t::replace), C#
#     (UnsafeRelaxedJsonEscaping), JavaScript (default), and Rust
#     (serde_json default) producers.
#
#   - `JSON::GeneratorError` is translated into `LingoFuse::IoError`,
#     so that callers have a single exception type to catch.
#
# Pretty-printing is deliberately not offered: indentation would break
# the byte-for-byte cross-language contract.
#
# ============================================================================
# JSON DESERIALIZATION POLICY
# ============================================================================
# `loads_json` uses `JSON.parse` with strict semantics. A payload that
# is not valid JSON raises `JSON::ParserError`. Callers that need a
# non-throwing path use `try_read_json`, which returns `nil` instead.
#
# Large-integer note: JSON numbers are parsed into Ruby `Integer` when
# they fit in 64 bits, and into `Float` otherwise. `JSON.parse` with
# the `decimal_class` option is not used; callers that need exact
# decimal arithmetic should negotiate the payload shape with the peer.
#
# ============================================================================
# LAZY LOADING
# ============================================================================
# This file attempts to require the DataHandle class, but tolerates its
# absence. If the native library is not installed, the JSON helpers
# (`dumps_json`, `loads_json`) remain fully usable; only the handle-based
# methods will fail at call time.
#
# ============================================================================

require 'json'

# Try to load the handle class. If the native library is unavailable,
# the JSON helper methods below remain usable.
begin
  require_relative 'data_handle'
rescue StandardError
  # Native library unavailable. The caller may still use the pure-JSON
  # helpers of this module, or install the library and re-require.
end

require_relative 'errors' if defined?(LingoFuse::Error).nil?

module LingoFuse
  # ----------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------

  # Unified JSON, string, and byte I/O for LingoFuse data handles.
  #
  # All methods are stateless. Concurrent access to the same DataHandle
  # must still be serialised by the caller, matching the contract of
  # LingoFuse::DataHandle.
  module LfIo
    # The NUL byte used as the string terminator on the wire.
    NUL_BYTE = 0x00

    # The only text encoding used on the wire.
    ENCODING = 'UTF-8'

    class << self
      # ==================================================================
      # JSON serialization policy (single source of truth)
      # ==================================================================

      # Serializes a Ruby value to a compact UTF-8 JSON string.
      #
      # The returned string does NOT include a trailing NUL byte. Callers
      # that want to write it to a data handle with the required NUL
      # terminator should use `write_json` or `write_string`.
      #
      # @param obj [Object] any JSON-serializable Ruby value
      # @return [String] compact UTF-8 JSON text
      # @raise [LingoFuse::IoError] when the value cannot be serialized
      def dumps_json(obj)
        JSON.generate(obj, ascii_only: false)
      rescue JSON::GeneratorError, TypeError => e
        raise IoError.new(
          "lf_io.dumps_json: JSON serialization failed: #{e.message}",
          operation: 'dumps_json'
        )
      end

      # Parses a UTF-8 JSON string into a Ruby value.
      #
      # Strict: any syntax error raises `JSON::ParserError`. Leading and
      # trailing whitespace is ignored. A UTF-8 BOM is NOT skipped;
      # strip it yourself if you need to accept BOM-prefixed input.
      #
      # @param text [String] a UTF-8 JSON document
      # @return [Object] the parsed value
      # @raise [JSON::ParserError] when the text is not valid JSON
      def loads_json(text)
        JSON.parse(text)
      end

      # ==================================================================
      # String I/O (NUL-framed UTF-8)
      # ==================================================================

      # Writes a string as UTF-8 bytes, followed by a NUL terminator.
      #
      # An empty string is written as a single NUL byte, matching every
      # other LingoFuse binding.
      #
      # @param handle [LingoFuse::DataHandle] target handle
      # @param value [String] UTF-8 text; nil is treated as empty
      # @return [void]
      def write_string(handle, value)
        handle.write_string(value.to_s)
        nil
      end

      # Reads a UTF-8 string from the handle, stopping at the first NUL.
      #
      # If no NUL is present, the entire remaining buffer is consumed
      # and decoded. Returns an empty string when the cursor is at or
      # past the end of the buffer, or when the first byte is a NUL.
      #
      # Invalid UTF-8 byte sequences are decoded with replacement
      # characters (U+FFFD). Callers that need to detect invalid UTF-8
      # should use `read_string_bytes` and inspect the raw bytes.
      #
      # @param handle [LingoFuse::DataHandle] source handle
      # @return [String]
      def read_string(handle)
        handle.read_string
      end

      # ==================================================================
      # Byte-oriented I/O (NUL-framed raw bytes)
      # ==================================================================

      # Writes raw bytes followed by a NUL terminator.
      #
      # The bytes are written verbatim; embedded NUL bytes are preserved
      # in the buffer. Note that the read side stops at the first NUL, so
      # an embedded NUL acts as a terminator on read. This asymmetry is
      # intentional and matches every other LingoFuse binding.
      #
      # @param handle [LingoFuse::DataHandle] target handle
      # @param data [String] raw bytes; nil is treated as empty
      # @return [void]
      def write_string_bytes(handle, data)
        bytes = data.nil? ? '' : data
        bytes = bytes.b unless bytes.encoding == Encoding::ASCII_8BIT
        handle.write_bytes(bytes) unless bytes.empty?
        handle.write_bytes("\x00".b)
        nil
      end

      # Reads raw bytes from the handle, stopping at the first NUL.
      #
      # Unlike `read_all_bytes`, which consumes the entire remaining
      # buffer, this stops at the NUL that `write_string` / `write_json`
      # append. The bytes are returned undecoded, so the caller can
      # inspect or forward them without a UTF-8 round-trip.
      #
      # @param handle [LingoFuse::DataHandle] source handle
      # @return [String] ASCII-8BIT string
      def read_string_bytes(handle)
        handle.read_string_bytes
      end

      # Reads raw bytes up to the first NUL WITHOUT advancing the cursor.
      #
      # Provided for diagnostic and logging code that needs to inspect
      # the current payload without consuming it. The cursor is restored
      # to its original value before returning.
      #
      # @param handle [LingoFuse::DataHandle] source handle
      # @return [String] ASCII-8BIT string
      def peek_string_bytes(handle)
        saved = handle.position
        begin
          read_string_bytes(handle)
        ensure
          handle.position = saved
        end
      end

      # Reads all remaining bytes from the handle, without NUL handling.
      #
      # The cursor is advanced to the end of the buffer. Use this for
      # raw binary payloads; use `read_string_bytes` for NUL-terminated
      # text or JSON payloads.
      #
      # @param handle [LingoFuse::DataHandle] source handle
      # @return [String] ASCII-8BIT string
      def read_all_bytes(handle)
        handle.read_all_bytes
      end

      # ==================================================================
      # JSON I/O (NUL-framed JSON)
      # ==================================================================

      # Serializes a Ruby value as UTF-8 JSON and writes it with a NUL
      # terminator.
      #
      # The serialization goes through `dumps_json`, so the compact and
      # non-ASCII-literal policy is guaranteed. The output never contains
      # a `\uXXXX` escape for non-ASCII text, and a trailing NUL byte is
      # always appended.
      #
      # @param handle [LingoFuse::DataHandle] target handle
      # @param obj [Object] the value to write
      # @return [void]
      def write_json(handle, obj)
        write_string(handle, dumps_json(obj))
      end

      # Reads a UTF-8 JSON payload from the handle and returns the
      # decoded Ruby value.
      #
      # The payload may or may not be NUL-terminated. If a NUL is
      # present, it is treated as the end of the payload; otherwise the
      # entire remaining buffer is consumed.
      #
      # Returns `nil` when the buffer contains no bytes at all. This
      # matches the historical convention of the toolchain: an empty
      # payload means "no result". Note that a JSON `null` (the four
      # bytes `null`) also decodes to `nil`; callers that need to
      # distinguish the two must inspect the raw buffer themselves via
      # `read_string_bytes`.
      #
      # @param handle [LingoFuse::DataHandle] source handle
      # @return [Object, nil]
      # @raise [JSON::ParserError] when the payload is not valid JSON
      def read_json(handle)
        text = read_string(handle)
        return nil if text.empty?
        loads_json(text)
      end

      # Non-throwing counterpart of `read_json`.
      #
      # The cursor is advanced regardless of whether the payload parses
      # successfully; this matches the historical behaviour of the C#
      # and C++ wrappers, and it is the only sensible choice for a probe.
      #
      # @param handle [LingoFuse::DataHandle] source handle
      # @return [Object, nil] the parsed value, or nil on empty / invalid
      def try_read_json(handle)
        text = read_string(handle)
        return nil if text.empty?
        begin
          loads_json(text)
        rescue JSON::ParserError
          nil
        end
      end

      # ==================================================================
      # C ABI string parameters
      # ==================================================================

      # Returns a UTF-8 string suitable for passing to an LF_* C-ABI
      # function that expects a `const char*` parameter.
      #
      # Fiddle's `:string` type handles NUL termination automatically when
      # the Ruby String is passed to an attached function, so this
      # helper exists purely for symmetry with the Python and C++
      # bindings, and to normalise nil to an empty string.
      #
      # @param value [String, nil]
      # @return [String]
      def cstr(value)
        (value || '').to_s
      end
    end
  end

  # ----------------------------------------------------------------------
  # DataHandle extension
  # ----------------------------------------------------------------------
  #
  # `data_handle.rb` already defines #read_string_bytes as a public
  # method. This block is a defensive re-opening: it only takes effect
  # when the class was loaded without that method (for example, if a
  # future refactor moves the method out of data_handle.rb). The guard
  # keeps the two definitions from clobbering each other.
  # ----------------------------------------------------------------------

  if defined?(DataHandle) &&
     !DataHandle.method_defined?(:read_string_bytes)
    class DataHandle
      # Reads raw bytes up to the first NUL, or all remaining bytes when
      # no NUL is present.
      #
      # The three-case rule is documented in the LfIo module header and
      # implemented in DataHandle#read_until_nul.
      #
      # @return [String] ASCII-8BIT string
      def read_string_bytes
        ensure_not_disposed!
        read_until_nul
      end
    end
  end
end