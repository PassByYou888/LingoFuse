# frozen_string_literal: true
#
# cross_call.rb — Concurrent load tester for the "ipc:cross" endpoint.
#
# Connects as a pure consumer (no application attached) and drives a
# fixed-duration load test against the "demo" application. Two APIs are
# exercised at random:
#
#     add      (int32 a, int32 b)                        -> int32
#     inv_seri (uint8, uint16, uint32, uint64,
#                string(NUL), float)                      -> reversed fields
#
# ============================================================================
# TARGET
# ============================================================================
# The "demo" application can be a Ruby node (cross_node.rb) or a node
# written in any other LingoFuse language. Set TARGET_APP to override
# the default when the mesh contains more than one "demo".
#
# ============================================================================
# CLEANUP ORDER
#     NetworkEvents.clear -> ExitMainThread -> Shutdown
# ============================================================================

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
  exit 1
end

ENDPOINT         = 'ipc:cross'
TARGET_APP       = ENV.fetch('TARGET_APP', 'demo')
WORKER_THREADS   = 32
TEST_SECONDS     = 10
CALL_TIMEOUT_MS  = 1000
PAUSE_MS         = 1
LOG_EVERY_N      = 5000
NUM_MIN          = 1
NUM_MAX          = 1000

# ----------------------------------------------------------------------------
# Thread-safe line output
# ----------------------------------------------------------------------------

LOG_MUTEX = Mutex.new

def log_line(msg)
  LOG_MUTEX.synchronize { $stdout.puts(msg) }
end

# ----------------------------------------------------------------------------
# Aggregate statistics
# ----------------------------------------------------------------------------

class Stats
  def initialize
    @mutex    = Mutex.new
    @total    = 0
    @success  = 0
    @failed   = 0
    @add      = 0
    @inv_seri = 0
  end

  def bump(field)
    @mutex.synchronize do
      case field
      when :total    then @total    += 1
      when :success  then @success  += 1
      when :failed   then @failed   += 1
      when :add      then @add      += 1
      when :inv_seri then @inv_seri += 1
      end
    end
  end

  def snapshot
    @mutex.synchronize do
      {
        total:    @total,
        success:  @success,
        failed:   @failed,
        add:      @add,
        inv_seri: @inv_seri
      }
    end
  end
end

# ----------------------------------------------------------------------------
# Remote call wrappers
# ----------------------------------------------------------------------------

def remote_add(a, b)
  param = LingoFuse::DataHandle.new('add')
  begin
    param.write_int32(a)
    param.write_int32(b)

    res = LingoFuse::Framework.call(TARGET_APP, param, CALL_TIMEOUT_MS)
    begin
      return nil if res.size < 4
      res.read_int32
    ensure
      res.dispose
    end
  rescue StandardError
    nil
  ensure
    param.dispose
  end
end

def remote_inv_seri
  param = LingoFuse::DataHandle.new('inv_seri')
  begin
    b   = 200
    w   = 0x10
    c   = 0x2F
    u64 = 0x3F
    s   = 'hello world'
    f   = 3.14

    param.write_uint8(b)
    param.write_uint16(w)
    param.write_uint32(c)
    param.write_uint64(u64)
    param.write_string(s)
    param.write_single(f)

    res = LingoFuse::Framework.call(TARGET_APP, param, CALL_TIMEOUT_MS)
    begin
      return nil if res.size.zero?

      rf   = res.read_single
      rs   = res.read_string
      ru64 = res.read_uint64
      rc   = res.read_uint32
      rw   = res.read_uint16
      rb   = res.read_uint8

      "reply: [#{rb}, #{rw}, #{rc}, #{ru64}, \"#{rs}\", #{rf}]" \
        "  original: [#{b}, #{w}, #{c}, #{u64}, \"#{s}\", #{f}]"
    ensure
      res.dispose
    end
  rescue StandardError
    nil
  ensure
    param.dispose
  end
end

# ----------------------------------------------------------------------------
# Worker thread body
# ----------------------------------------------------------------------------

def worker(index, stop_flag, stats)
  rng  = Random.new(index)
  iter = 0

  until stop_flag[:stop]
    iter += 1
    do_log = (iter % LOG_EVERY_N).zero?

    if rng.rand < 0.5
      a = rng.rand(NUM_MIN..NUM_MAX)
      b = rng.rand(NUM_MIN..NUM_MAX)
      result = remote_add(a, b)

      stats.bump(:total)
      stats.bump(:add)

      if result
        stats.bump(:success)
        log_line("[Call #{index}] add(#{a}, #{b}) = #{result}") if do_log
      else
        stats.bump(:failed)
        log_line("[Call #{index}] add(#{a}, #{b}) timed out or failed.") if do_log
      end
    else
      result = remote_inv_seri

      stats.bump(:total)
      stats.bump(:inv_seri)

      if result
        stats.bump(:success)
        log_line("[Call #{index}] #{result}") if do_log
      else
        stats.bump(:failed)
        log_line("[Call #{index}] inv_seri timed out or failed.") if do_log
      end
    end

    sleep(PAUSE_MS / 1000.0) if PAUSE_MS.positive?
  end
end

# ----------------------------------------------------------------------------
# Lifecycle
# ----------------------------------------------------------------------------

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
  puts '=== Cross Call (Client) ==='

  begin
    LingoFuse::Framework.set_option('Wait_Connection_ReadyOk', 'True')
    LingoFuse::Framework.set_option('Overlap_Connection', 'True')
    LingoFuse::Framework.set_option('Wait_Connection_Timeout', '10000')

    LingoFuse::Framework.reset_prepare

    tag = LingoFuse::Framework.prepare_client(ENDPOINT, nil)
    puts "[Call] Connected to #{ENDPOINT} (tag=#{tag})"

    done = LingoFuse::Framework.prepare_done
    puts "[Call] prepare_done = #{done}"

    unless LingoFuse::Status.check_app(TARGET_APP)
      print "[Call] Waiting for target '#{TARGET_APP}' to appear"
      30.times do
        break if LingoFuse::Status.check_app(TARGET_APP)
        print '.'
        sleep 0.2
      end
      puts
    end

    if LingoFuse::Status.check_app(TARGET_APP)
      puts "[Call] Target '#{TARGET_APP}' is visible."
    else
      puts "[Call] WARNING: target '#{TARGET_APP}' is not visible yet."
      puts '[Call] Starting the load test anyway; every call will time out.'
    end

    puts "[Call] Starting #{TEST_SECONDS}-second load test with " \
         "#{WORKER_THREADS} threads..."

    stats     = Stats.new
    stop_flag = { stop: false }
    threads   = []

    start_time = Time.now

    WORKER_THREADS.times do |i|
      threads << Thread.new { worker(i, stop_flag, stats) }
    end

    sleep(TEST_SECONDS)
    stop_flag[:stop] = true
    threads.each(&:join)

    elapsed  = Time.now - start_time
    snapshot = stats.snapshot

    total        = snapshot[:total]
    success      = snapshot[:success]
    failed       = snapshot[:failed]
    add_calls    = snapshot[:add]
    inv_calls    = snapshot[:inv_seri]

    success_rate = total.positive? ? (100.0 * success / total) : 0.0
    throughput   = elapsed.positive? ? (total / elapsed) : 0.0
    succ_thru    = elapsed.positive? ? (success / elapsed) : 0.0

    puts
    puts '[Call] Load test summary'
    puts format('         duration          : %.3f s', elapsed)
    puts format('         total calls       : %d', total)
    puts format('         success           : %d (%.2f %%)', success, success_rate)
    puts format('         failed            : %d', failed)
    puts format('         add calls         : %d', add_calls)
    puts format('         inv_seri calls    : %d', inv_calls)
    puts format('         throughput        : %.2f calls/s', throughput)
    puts format('         success throughput: %.2f calls/s', succ_thru)

    puts '[Call] Press Enter to exit...'
    $stdin.gets
  rescue StandardError => e
    warn "[Call] FATAL: #{e.class}: #{e.message}"
    cleanup
    return 1
  end

  cleanup
  puts '[Call] Bye.'
  0
end

exit(main)