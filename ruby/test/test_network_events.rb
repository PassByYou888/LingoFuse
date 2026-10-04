# frozen_string_literal: true
#
# test_network_events.rb — Unit tests for NetworkEvents, the listener
# base class, and NetworkEventQueue.
#
# ============================================================================
# SAFETY CONSTRAINT
# ============================================================================
# This file deliberately NEVER triggers a real connect or disconnect
# event. Doing so would dispatch a user callback on a native worker
# thread, which Fiddle cannot marshal onto the Ruby interpreter; MRI
# would then raise "[BUG] rb_thread_call_with_gvl() is called by
# non-ruby thread" and deadlock the process.
#
# Every test here exercises only the installation plumbing: which
# handlers are stored, whether installed? reflects the state, and how
# the pure-Ruby NetworkEventQueue behaves. The actual callback firing
# path is not testable from Fiddle (see test_network.rb's file header
# for the full discussion).
#
# ============================================================================

require 'minitest/autorun'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

class TestNetworkEvents < Minitest::Test
  def setup
    unless defined?(LingoFuse::NetworkEvents) && LingoFuse.loaded?
      skip 'native library not loaded'
    end
    # Always start from a clean slot. A stray callback would be
    # dispatched the moment any connection succeeds.
    LingoFuse::NetworkEvents.clear
  end

  def teardown
    begin
      LingoFuse::NetworkEvents.clear
    rescue StandardError
      # ignored
    end
  end

  # ==================================================================
  # set / clear / installed?
  # ==================================================================

  def test_installed_is_false_initially
    refute LingoFuse::NetworkEvents.installed?
  end

  def test_set_installs_both_handlers
    LingoFuse::NetworkEvents.set(
      on_connect:    ->(_addr) {},
      on_disconnect: ->(_addr) {}
    )
    assert LingoFuse::NetworkEvents.installed?
  end

  def test_set_with_only_connect
    LingoFuse::NetworkEvents.set(on_connect: ->(_addr) {})
    assert LingoFuse::NetworkEvents.installed?
  end

  def test_set_with_only_disconnect
    LingoFuse::NetworkEvents.set(on_disconnect: ->(_addr) {})
    assert LingoFuse::NetworkEvents.installed?
  end

  def test_set_with_both_nil_clears
    LingoFuse::NetworkEvents.set(
      on_connect:    ->(_addr) {},
      on_disconnect: ->(_addr) {}
    )
    assert LingoFuse::NetworkEvents.installed?

    LingoFuse::NetworkEvents.set(on_connect: nil, on_disconnect: nil)
    refute LingoFuse::NetworkEvents.installed?
  end

  def test_clear_is_idempotent
    LingoFuse::NetworkEvents.clear
    LingoFuse::NetworkEvents.clear
    refute LingoFuse::NetworkEvents.installed?
  end

  def test_clear_after_set
    LingoFuse::NetworkEvents.set(
      on_connect:    ->(_addr) {},
      on_disconnect: ->(_addr) {}
    )
    LingoFuse::NetworkEvents.clear
    refute LingoFuse::NetworkEvents.installed?
  end

  # ==================================================================
  # Argument validation
  # ==================================================================

  def test_set_rejects_non_callable_connect
    assert_raises(ArgumentError) do
      LingoFuse::NetworkEvents.set(on_connect: 'not callable')
    end
  end

  def test_set_rejects_non_callable_disconnect
    assert_raises(ArgumentError) do
      LingoFuse::NetworkEvents.set(on_disconnect: 42)
    end
  end

  def test_set_accepts_a_proc
    LingoFuse::NetworkEvents.set(on_connect: proc { |_a| })
    assert LingoFuse::NetworkEvents.installed?
  end

  def test_set_accepts_a_lambda
    LingoFuse::NetworkEvents.set(on_connect: ->(_a) {})
    assert LingoFuse::NetworkEvents.installed?
  end

  # ==================================================================
  # set_listener
  # ==================================================================

  def test_set_listener_with_nil_clears
    LingoFuse::NetworkEvents.set(
      on_connect: ->(_a) {}
    )
    LingoFuse::NetworkEvents.set_listener(nil)
    refute LingoFuse::NetworkEvents.installed?
  end

  def test_set_listener_installs_object
    listener = LingoFuse::NetworkEventListener.new
    LingoFuse::NetworkEvents.set_listener(listener)
    assert LingoFuse::NetworkEvents.installed?
  end

  def test_set_listener_rejects_non_listener
    assert_raises(ArgumentError) do
      LingoFuse::NetworkEvents.set_listener(Object.new)
    end
  end

  # ==================================================================
  # NetworkEventListener base class
  # ==================================================================

  def test_listener_base_class_is_defined
    assert defined?(LingoFuse::NetworkEventListener)
  end

  def test_listener_base_methods_are_noops
    listener = LingoFuse::NetworkEventListener.new
    assert_nil listener.on_connect('addr')
    assert_nil listener.on_disconnect('addr')
  end

  def test_listener_subclass_can_override
    klass = Class.new(LingoFuse::NetworkEventListener) do
      attr_reader :events
      def initialize
        @events = []
      end
      def on_connect(addr)
        @events << [:connect, addr]
      end
      def on_disconnect(addr)
        @events << [:disconnect, addr]
      end
    end

    listener = klass.new
    listener.on_connect('a')
    listener.on_disconnect('b')
    assert_equal [[:connect, 'a'], [:disconnect, 'b']], listener.events
  end

  # ==================================================================
  # NetworkEventQueue — pure Ruby, no native callback path
  # ==================================================================

  def test_queue_new_default_size
    q = LingoFuse::NetworkEventQueue.new
    assert q.empty?
    assert_equal 0, q.size
  end

  def test_queue_new_with_max_size
    q = LingoFuse::NetworkEventQueue.new(max_size: 8)
    assert q.empty?
  end

  def test_queue_new_rejects_non_positive_size
    assert_raises(ArgumentError) do
      LingoFuse::NetworkEventQueue.new(max_size: 0)
    end
    assert_raises(ArgumentError) do
      LingoFuse::NetworkEventQueue.new(max_size: -1)
    end
  end

  def test_queue_enqueue_dequeue
    q = LingoFuse::NetworkEventQueue.new(max_size: 16)
    q.send(:enqueue, :connect, 'addr-1')
    q.send(:enqueue, :disconnect, 'addr-2')

    assert_equal 2, q.size

    type1, addr1 = q.get
    type2, addr2 = q.get

    assert_equal :connect,    type1
    assert_equal 'addr-1',    addr1
    assert_equal :disconnect, type2
    assert_equal 'addr-2',    addr2
    assert q.empty?
  end

  def test_queue_get_with_timeout_raises_when_empty
    q = LingoFuse::NetworkEventQueue.new(max_size: 4)
    assert_raises(ThreadError) { q.get(timeout: 0.05) }
  end

  def test_queue_clear
    q = LingoFuse::NetworkEventQueue.new(max_size: 4)
    q.send(:enqueue, :connect, 'a')
    q.send(:enqueue, :connect, 'b')
    q.clear
    assert q.empty?
  end

  def test_queue_global_instance_is_singleton
    a = LingoFuse::NetworkEventQueue.global_instance
    b = LingoFuse::NetworkEventQueue.global_instance
    assert_same a, b
  end

  def test_queue_install_uninstall_toggles_state
    q = LingoFuse::NetworkEventQueue.new(max_size: 8)
    begin
      q.install
      assert LingoFuse::NetworkEvents.installed?
    ensure
      q.uninstall
    end
    refute LingoFuse::NetworkEvents.installed?
  end

  def test_queue_install_is_idempotent
    q = LingoFuse::NetworkEventQueue.new(max_size: 8)
    begin
      q.install
      q.install
      assert LingoFuse::NetworkEvents.installed?
    ensure
      q.uninstall
    end
  end

  def test_queue_uninstall_is_idempotent
    q = LingoFuse::NetworkEventQueue.new(max_size: 8)
    q.uninstall
    q.uninstall
    refute LingoFuse::NetworkEvents.installed?
  end
end