# frozen_string_literal: true
#
# cross_service.rb — Coordinator process for the IPC endpoint "ipc:cross".
#
# Creates the IPC service endpoint "ipc:cross" and prepares a self-
# connected client. It does NOT register any application; it exists
# solely as a discovery / anchor endpoint for the worker nodes and
# callers to connect to.
#
# Behaviour is identical to the C++ CrossService.cpp, the C# CrossService,
# and the Pascal cross_service.lpr demo. Any mix of language runtimes can
# participate in the same mesh.
#
# Cleanup order (matching Pascal LF-CLEAN-001):
#     NetworkEvents.clear -> ExitMainThread -> Shutdown
#
# Usage:
#
#     ruby cross/cross_service.rb
#
# Requires:
#     LINGOFUSE_LIB_PATH points at the directory containing the native
#     LingoFuse shared library.
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

def wait_for_enter
  puts 'Press Enter to exit...'
  $stdin.gets
end

def cleanup
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
    LingoFuse::Framework.shutdown
  rescue StandardError
    # ignored
  end
end

def main
  puts '=== Cross Service (Coordinator) ==='

  begin
    LingoFuse::Framework.set_option('Wait_Connection_ReadyOk', 'True')
    LingoFuse::Framework.set_option('Overlap_Connection', 'True')
    LingoFuse::Framework.set_option('Wait_Connection_Timeout', '10000')

    LingoFuse::Framework.reset_prepare

    serv_tag = LingoFuse::Framework.prepare_service(ENDPOINT, ENDPOINT)
    puts "[Service] Prepared service endpoint #{ENDPOINT} (tag=#{serv_tag})"

    client_tag = LingoFuse::Framework.prepare_client(ENDPOINT, nil)
    puts "[Service] Prepared client tunnel (tag=#{client_tag})"

    done = LingoFuse::Framework.prepare_done
    if done
      puts "[Service] IPC service '#{ENDPOINT}' is running."
    else
      puts '[Service] prepare_done returned false (framework already running?).'
      puts '[Service] Continuing anyway.'
    end

    wait_for_enter

    puts '[Service] Shutting down...'
  rescue StandardError => e
    warn "[Service] FATAL: #{e.class}: #{e.message}"
    cleanup
    return 1
  end

  cleanup
  puts '[Service] Bye.'
  0
end

exit(main)