# frozen_string_literal: true
#
# errors.rb — Exception hierarchy for the LingoFuse Ruby binding.
#
# Every failure raised by this binding is an instance of LingoFuse::Error
# or one of its subclasses. Callers may rescue the base type for a single
# catch-all handler, or rescue a specific subclass for fine-grained
# recovery.
#
# The hierarchy mirrors the layer at which the failure occurred:
#
#     base class            LingoFuse::Error
#     library load          LingoFuse::LibraryLoadError
#     remote call           LingoFuse::CallError
#     I/O on a handle       LingoFuse::IoError
#     use after dispose     LingoFuse::ObjectDisposedError
#     API registration      LingoFuse::RegistrationError
#     callback body failure LingoFuse::CallbackError
#
# Only these seven types exist. Custom exception types for conditions
# that the current implementation cannot actually raise are deliberately
# absent. If a new failure mode is introduced, its exception type is
# added here, not invented at a call site.
#

module LingoFuse
  # Base class for all LingoFuse exceptions.
  class Error < StandardError
  end

  # Raised when the native LingoFuse shared library cannot be located
  # or loaded by the platform resolver.
  #
  # Typical causes:
  #   - the DLL / .so / .dylib is not next to the executable and is not
  #     on the loader search path;
  #   - it has an architecture mismatch (a 64-bit host trying to load a
  #     32-bit library, or vice versa);
  #   - a dependent native library (for example the IPC library) is
  #     missing.
  class LibraryLoadError < Error
  end

  # Raised when a remote Call fails: a null handle returned by the
  # native layer, a timeout, or an unreachable target application.
  #
  # The C ABI reports a failed Call as an empty handle (size 0), never
  # as a NULL pointer. This exception is the Ruby representation of that
  # failure, and it is also raised when the native layer itself returns
  # a NULL handle (a more fundamental transport problem).
  class CallError < Error
    # @return [String, nil] name of the target application, if known
    attr_reader :target_app

    # @return [String, nil] name of the target API, if known
    attr_reader :target_api

    def initialize(message, target_app: nil, target_api: nil)
      super(message)
      @target_app = target_app
      @target_api = target_api
    end
  end

  # Raised when a low-level I/O operation on a data handle fails: a
  # short read when the caller asked for a fixed number of bytes, or a
  # short write when the native layer accepted fewer bytes than
  # requested.
  #
  # This exception is reserved for the byte-level contract of a data
  # handle. Argument validation errors use the standard Ruby exceptions
  # (ArgumentError, TypeError).
  class IoError < Error
    # @return [String, nil] name of the failing I/O operation
    attr_reader :operation

    def initialize(message, operation: nil)
      super(message)
      @operation = operation
    end
  end

  # Raised when an operation is attempted on an object that has already
  # been disposed.
  class ObjectDisposedError < Error
    # @return [String] name of the disposed object, for diagnostics
    attr_reader :object_name

    def initialize(object_name)
      super("The #{object_name} has already been disposed.")
      @object_name = object_name
    end
  end

  # Raised when API registration is rejected by the native layer. The
  # most common cause is a duplicate API name on the same application.
  class RegistrationError < Error
    # @return [String, nil] API name that was rejected
    attr_reader :api_name

    def initialize(message, api_name: nil)
      super(message)
      @api_name = api_name
    end
  end

  # Raised to describe a user callback that threw an unhandled
  # exception while running on a native worker thread.
  #
  # This error is never thrown into user code directly; it is passed to
  # the process-level callback error reporter (see `callback_error.rb`
  # in a later batch). It exists so that the reporter receives a
  # structured object with a stable type, rather than a raw value the
  # callback happened to throw.
  class CallbackError < Error
    # @return [String] identifier of the callback site that raised
    attr_reader :source

    # @return [Object] the original value thrown by the callback body
    attr_reader :original_cause

    def initialize(source, cause)
      detail = cause.is_a?(Exception) ? cause.message : cause.to_s
      super("Callback '#{source}' raised: #{detail}")
      @source = source
      @original_cause = cause
    end
  end
end