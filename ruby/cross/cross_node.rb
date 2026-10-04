# frozen_string_literal: true
#
# cross_node.rb — Worker node that registers the "add" and "inv_seri"
# Call APIs under application "demo".
#
# ============================================================================
# HOW THIS NODE RECEIVES CALLS
# ============================================================================
# The Ruby binding uses the lingofuse_ext C extension to receive
# callbacks. LingoFuse invokes a Call / Notify handler from a native
# worker thread that does not hold the GVL; the C extension enqueues the
# request and a dedicated Ruby dispatcher thread runs the user block.
#
# Without the extension, Fiddle's callback path would deadlock the
# process on the first incoming call. With the extension present, the
# node is a fully functional LingoFuse peer.
#
# ============================================================================
# WIRE FORMAT — must match every other language binding exactly
# ============================================================================
#   add      (int32 a, int32 b)                        -> int32
#   inv_seri (uint8, uint16, uint32, uint64,
#              string(NUL), float)                      -> reversed fields
#
# All integers are little-endian. The string is UTF-8, NUL-terminated.
#
# ============================================================================
# Usage:
#
#     ruby cross/cross_node.rb
#
# Requires:
#     A running CrossService on ipc:cross (any language).
# ============================================================================

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
  exit 1
end

ENDPOINT = 'ipc:cross'
APP_NAME = 'demo'

# ----------------------------------------------------------------------------
# Callbacks
# ----------------------------------------------------------------------------

# add(int32, int32) -> int32
def handle_add(input, output)
  a = input.read_int32
  b = input.read_int32
  c = a + b
  puts "[Node] add(#{a}, #{b}) = #{c}"
  output.write_int32(c)
end

# inv_seri(uint8, uint16, uint32, uint64, string, float) -> reversed
def handle_inv_seri(input, output)
  b    = input.read_uint8
  w    = input.read_uint16
  c    = input.read_uint32
  u64  = input.read_uint64
  s    = input.read_string
  f    = input.read_single

  puts "[Node] inv_seri received: [#{b}, #{w}, #{c}, #{u64}, \"#{s}\", #{f}]"

  # Reply in reverse field order.
  output.write_single(f)
  output.write_string(s)
  output.write_uint64(u64)
  output.write_uint32(c)
  output.write_uint16(w)
  output.write_uint8(b)

  puts "[Node] inv_seri replied:  [#{f}, \"#{s}\", #{u64}, #{c}, #{w}, #{b}]"
end

def cleanup(app)
  begin
    LingoFuse::NetworkEvents.clear
  rescue StandardError
    # ignored
  end
  begin
    LingoFuse::Framework.exit_main_thread
  rescue StandardError
    # ignored
  end
  begin
    app.dispose if app
  rescue StandardError
    # ignored
  end
  begin
    LingoFuse::Framework.shutdown
  rescue StandardError
    # ignored
  end
end

def main
  puts '=== Cross Node (Worker) ==='

  unless LingoFuse::NativeBridge.available?
    warn '[Node] FATAL: lingofuse_ext is not available.'
    warn '[Node] Build it with setup_build_env.ps1 and try again.'
    return 1
  end

  app = nil
  begin
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.set_option('Overlap_Connection', 'True')

    LingoFuse::Framework.reset_prepare

    app = LingoFuse::AppHandle.new(APP_NAME, 'Ruby worker node')

    app.register_call('add', 'add(int a, int b) -> int') do |input, output|
      handle_add(input, output)
    end

    app.register_call('inv_seri', 'inv_seri() -> reversed types') do |input, output|
      handle_inv_seri(input, output)
    end

    tag = LingoFuse::Framework.prepare_client(ENDPOINT, app)
    puts "[Node] Registered 'add' and 'inv_seri' under '#{APP_NAME}'."
    puts "[Node] Connected to #{ENDPOINT} (tag=#{tag})"

    done = LingoFuse::Framework.prepare_done
    puts "[Node] prepare_done = #{done}"

    puts '[Node] Online. Press Enter to exit...'
    $stdin.gets

    puts '[Node] Shutting down...'
  rescue StandardError => e
    warn "[Node] FATAL: #{e.class}: #{e.message}"
    cleanup(app)
    return 1
  end

  cleanup(app)
  puts '[Node] Bye.'
  0
end

exit(main)