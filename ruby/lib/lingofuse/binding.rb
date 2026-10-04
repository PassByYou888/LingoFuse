# frozen_string_literal: true
#
# binding.rb — Low-level Fiddle declarations for the LingoFuse C ABI.
#
# This module is the ONLY place in the Ruby binding where native code is
# invoked. It uses Ruby's standard-library Fiddle (not the FFI gem).
#
# ============================================================================
# WHY FIDDLE
# ============================================================================
# Fiddle uses the Windows API LoadLibrary without the
# LOAD_WITH_ALTERED_SEARCH_PATH flag. This means:
#
#   1. A bare file name is resolved against the standard Windows DLL
#      search order, including every directory on PATH.
#   2. Dependent DLLs (z_ipc_64.dll, mimalloc64.dll) are resolved
#      against the same standard search order.
#   3. No absolute path is required at the call site.
#
# ============================================================================
# NATIVE LIBRARY DISCOVERY
# ============================================================================
# The shared library is located by trying a fixed list of candidate
# absolute paths, in order. The first one that exists on disk is loaded.
#
# Search order:
#
#   1. $LINGOFUSE_LIB_PATH/<library name>              (explicit override)
#   2. $PWD/<library name>                             (current directory)
#   3. <binding.rb dir>/<library name>                 (sibling of this file)
#   4. <binding.rb dir>/../Binary/<library name>       (lib/Binary/)
#   5. <binding.rb dir>/../../Binary/<library name>    (ruby/Binary/)
#   6. <binding.rb dir>/../../../Binary/<library name> (project root Binary/)
#   7. The bare library name                           (OS loader / PATH)
#
# When a candidate is loaded from an absolute path, its containing
# directory is first registered with SetDllDirectoryW (Windows only) so
# that dependent DLLs are found. On Linux and macOS, the loader search
# path is controlled by LD_LIBRARY_PATH / DYLD_LIBRARY_PATH and no
# per-load registration is required.
#
# If no candidate path exists, Fiddle.dlopen is called with the bare
# name and the OS loader's standard search order applies.
#
# ============================================================================
# CALLBACK LIFETIME
# ============================================================================
# Fiddle::Closure objects are Ruby objects. The native library stores
# only the underlying function pointer. If the Ruby object is
# garbage-collected while the native library still holds the pointer,
# the next invocation jumps into freed memory and crashes the process.
#
# The high-level wrappers (app_handle.rb, network_events.rb) satisfy
# this requirement by storing callbacks in instance-level or module-level
# registries.
#
# ============================================================================

require 'fiddle'
require 'fiddle/import'
require 'rbconfig'

require_relative 'errors'

module LingoFuse
  # ========================================================================
  # Platform detection
  # ========================================================================

  # Returns the platform-specific shared library file name.
  #
  # @return [String]
  def self.platform_library_name
    os = RbConfig::CONFIG['host_os'].to_s

    if os =~ /mswin|mingw|cygwin/i
      # Use the actual pointer width. `1.size` reflects the size of a C
      # `long` (4 bytes even on 64-bit Windows, LLP64 model), which
      # would wrongly select LingoFuse32.dll.
      pointer_size = [''].pack('p').size
      pointer_size == 8 ? 'LingoFuse64.dll' : 'LingoFuse32.dll'
    elsif os =~ /darwin/i
      'liblingofuse.dylib'
    else
      'liblingofuse.so'
    end
  end

  # ========================================================================
  # Candidate path search
  # ========================================================================

  # Returns the ordered list of absolute paths to try, given a library
  # file name. Duplicates are removed while preserving the original order.
  #
  # The list mirrors the search strategy documented in
  # INSTALL_DEPENDENCIES.md so that the documented behaviour and the
  # actual behaviour never diverge.
  #
  # @param lib_name [String]
  # @return [Array<String>]
  def self.candidate_library_paths(lib_name)
    here = __dir__

    list = []

    # 1. Explicit override. LINGOFUSE_LIB_PATH always wins.
    env_dir = ENV['LINGOFUSE_LIB_PATH']
    if env_dir && !env_dir.strip.empty?
      list << File.join(env_dir, lib_name)
    end

    # 2. Current working directory.
    list << File.join(Dir.pwd, lib_name)

    # 3. Sibling of this file (lib/lingofuse/).
    list << File.join(here, lib_name)

    # 4. lib/Binary/ — in-package layout.
    list << File.join(here, '..', 'Binary', lib_name)

    # 5. ruby/Binary/ — the binding's own Binary directory.
    list << File.join(here, '..', '..', 'Binary', lib_name)

    # 6. <project>/Binary/ — standard repository layout:
    #      <project>/ruby/lib/lingofuse/binding.rb
    #      <project>/Binary/LingoFuse64.dll
    list << File.join(here, '..', '..', '..', 'Binary', lib_name)

    list.uniq
  end

  # ========================================================================
  # Windows dependency directory registration
  # ========================================================================

  # Registers a directory with SetDllDirectoryW so that subsequent
  # LoadLibrary calls resolve dependent DLLs (z_ipc_64.dll,
  # mimalloc64.dll) from that directory as well.
  #
  # On Windows the call is required because LoadLibrary does NOT
  # automatically search the loaded DLL's own directory for its
  # dependencies. On Linux and macOS this is a no-op: the loader resolves
  # dependencies through RPATH / LD_LIBRARY_PATH / DYLD_LIBRARY_PATH.
  #
  # @param dir [String] absolute directory path
  # @return [void]
  def self.register_dll_directory(dir)
    return unless RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i
    return if dir.nil? || dir.empty?

    begin
      kernel32 = Fiddle.dlopen('kernel32.dll')
      set_dll_dir = Fiddle::Function.new(
        kernel32['SetDllDirectoryW'],
        [Fiddle::TYPE_VOIDP],
        Fiddle::TYPE_INT
      )
      # Build a UTF-16LE, NUL-terminated copy of the directory path in
      # Fiddle-managed memory. The explicit malloc avoids relying on
      # Fiddle::Pointer[...] behaviour, which is not a stable public API
      # across Fiddle versions.
      wide     = dir.encode('UTF-16LE')
      wide_buf = wide + "\x00".encode('UTF-16LE')
      wide_ptr = Fiddle::Pointer.malloc(wide_buf.bytesize)
      wide_ptr[0, wide_buf.bytesize] = wide_buf
      set_dll_dir.call(wide_ptr)
    rescue StandardError
      # Best effort. If SetDllDirectoryW is unavailable for any reason,
      # the load below will still attempt the standard search order.
    end
  end

  # ========================================================================
  # Library loading
  # ========================================================================

  # Loads the native LingoFuse shared library.
  #
  # Tries every candidate path in order. The first one that exists on
  # disk is loaded (after its containing directory is registered with
  # SetDllDirectoryW on Windows). If none exists, the bare file name is
  # passed to Fiddle.dlopen and the OS loader's standard search order
  # applies.
  #
  # @param lib_name [String]
  # @return [Object] the Fiddle library handle
  # @raise [LibraryLoadError] when no candidate can be loaded
  def self.load_native_library(lib_name)
    errors = []

    candidate_library_paths(lib_name).each do |path|
      next unless File.file?(path)

      begin
        register_dll_directory(File.dirname(path))
        return Fiddle.dlopen(path)
      rescue Fiddle::DLError => e
        errors << "#{path}: #{e.message}"
      end
    end

    # Fall back to the bare name. The OS loader will search PATH and the
    # standard system directories.
    begin
      return Fiddle.dlopen(lib_name)
    rescue Fiddle::DLError => e
      errors << "#{lib_name} (via OS loader): #{e.message}"
    end

    raise LibraryLoadError, build_load_error_message(lib_name, errors)
  end

  # Builds a clear, actionable error message listing every attempt.
  def self.build_load_error_message(lib_name, errors)
    lines = []
    lines << "Failed to load the LingoFuse native library '#{lib_name}'."
    lines << ''
    lines << 'Attempts:'
    if errors.empty?
      lines << '  (no candidate path existed on disk, and the OS loader ' \
               'search also failed)'
    else
      errors.each { |e| lines << "  - #{e}" }
    end
    lines << ''
    lines << 'To make the library discoverable, do ONE of the following:'
    lines << ''
    lines << '  1. Place the file next to this binding:'
    lines << '       ruby/lib/lingofuse/' + lib_name
    lines << ''
    lines << '  2. Place it in the standard repository layout:'
    lines << '       <project>/Binary/' + lib_name
    lines << ''
    lines << '  3. Place it in the current working directory, or on PATH.'
    lines << ''
    lines << '  4. Set LINGOFUSE_LIB_PATH to the directory containing it:'
    lines << '       $env:LINGOFUSE_LIB_PATH = "<directory>"'
    lines << ''
    lines << 'On Windows, LingoFuse64.dll also needs its runtime dependencies'
    lines << '(z_ipc_64.dll, mimalloc64.dll) in the same directory.'
    lines.join("\n")
  end

  # ========================================================================
  # Load the shared library at module load time
  # ========================================================================

  _lib_name = platform_library_name
  @handle   = load_native_library(_lib_name)

  # ========================================================================
  # Function binding helper
  # ========================================================================

  # Binds one symbol from the loaded library.
  #
  # @param name [String]
  # @param args [Array<Integer>] Fiddle argument type constants
  # @param ret  [Integer] Fiddle return type constant
  # @return [Fiddle::Function]
  def self.bind(name, args, ret)
    Fiddle::Function.new(@handle[name], args, ret)
  end

  # ========================================================================
  # Data handle operations (10)
  # ========================================================================

  LF_CreateData = bind('LF_CreateData',
                       [Fiddle::TYPE_VOIDP],
                       Fiddle::TYPE_VOIDP)

  LF_CreateData_Permanent = bind('LF_CreateData_Permanent',
                                 [Fiddle::TYPE_VOIDP],
                                 Fiddle::TYPE_VOIDP)

  LF_FreeData = bind('LF_FreeData',
                     [Fiddle::TYPE_VOIDP],
                     Fiddle::TYPE_VOID)

  LF_GetBuffer = bind('LF_GetBuffer',
                      [Fiddle::TYPE_VOIDP],
                      Fiddle::TYPE_VOIDP)

  LF_WriteBuffer = bind('LF_WriteBuffer',
                        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                         Fiddle::TYPE_LONG_LONG],
                        Fiddle::TYPE_LONG_LONG)

  LF_ReadBuffer = bind('LF_ReadBuffer',
                       [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                        Fiddle::TYPE_LONG_LONG],
                       Fiddle::TYPE_LONG_LONG)

  LF_GetPos = bind('LF_GetPos',
                   [Fiddle::TYPE_VOIDP],
                   Fiddle::TYPE_LONG_LONG)

  LF_SetPos = bind('LF_SetPos',
                   [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG],
                   Fiddle::TYPE_VOID)

  LF_GetSize = bind('LF_GetSize',
                    [Fiddle::TYPE_VOIDP],
                    Fiddle::TYPE_LONG_LONG)

  LF_SetSize = bind('LF_SetSize',
                    [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG],
                    Fiddle::TYPE_VOID)

  # ========================================================================
  # Application handle operations (5)
  # ========================================================================

  LF_CreateApp = bind('LF_CreateApp',
                      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                      Fiddle::TYPE_VOIDP)

  LF_FreeApp = bind('LF_FreeApp',
                    [Fiddle::TYPE_VOIDP],
                    Fiddle::TYPE_VOID)

  LF_Generate_AppName = bind('LF_Generate_AppName',
                             [],
                             Fiddle::TYPE_VOIDP)

  LF_Get_AppName = bind('LF_Get_AppName',
                        [Fiddle::TYPE_VOIDP],
                        Fiddle::TYPE_VOIDP)

  LF_BindApp = bind('LF_BindApp',
                    [Fiddle::TYPE_VOIDP],
                    Fiddle::TYPE_INT)

  # ========================================================================
  # API registration (3)
  # ========================================================================

  LF_RegisterCall = bind('LF_RegisterCall',
                         [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                          Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                          Fiddle::TYPE_VOIDP],
                         Fiddle::TYPE_INT)

  LF_RegisterNotify = bind('LF_RegisterNotify',
                           [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                            Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                            Fiddle::TYPE_VOIDP],
                           Fiddle::TYPE_INT)

  LF_Unregister = bind('LF_Unregister',
                       [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                       Fiddle::TYPE_INT)

  # ========================================================================
  # Local execution (2)
  # ========================================================================

  LF_LocalCall = bind('LF_LocalCall',
                      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                      Fiddle::TYPE_VOIDP)

  LF_LocalNotify = bind('LF_LocalNotify',
                        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                        Fiddle::TYPE_VOID)

  # ========================================================================
  # Network preparation (5)
  # ========================================================================

  LF_ResetPrepare = bind('LF_ResetPrepare', [], Fiddle::TYPE_VOID)

  LF_PrepareService = bind('LF_PrepareService',
                           [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                           Fiddle::TYPE_INT)

  LF_PrepareClient = bind('LF_PrepareClient',
                          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                          Fiddle::TYPE_INT)

  LF_PrepareDone = bind('LF_PrepareDone', [], Fiddle::TYPE_INT)

  LF_ExitMainThread = bind('LF_ExitMainThread', [], Fiddle::TYPE_VOID)

  # ========================================================================
  # Remote invocation (3)
  # ========================================================================

  LF_Call = bind('LF_Call',
                 [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                  Fiddle::TYPE_LONG_LONG],
                 Fiddle::TYPE_VOIDP)

  LF_Notify = bind('LF_Notify',
                   [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                   Fiddle::TYPE_VOID)

  LF_Sequenced_Notify = bind('LF_Sequenced_Notify',
                             [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                             Fiddle::TYPE_VOID)

  # ========================================================================
  # Options and diagnostics (7)
  # ========================================================================

  LF_SetOption = bind('LF_SetOption',
                      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                      Fiddle::TYPE_VOID)

  LF_GetStatusCount = bind('LF_GetStatusCount', [], Fiddle::TYPE_INT)

  LF_GetStatus = bind('LF_GetStatus', [], Fiddle::TYPE_VOIDP)

  LF_PostStatus = bind('LF_PostStatus',
                       [Fiddle::TYPE_VOIDP],
                       Fiddle::TYPE_VOID)

  LF_CheckMainThread = bind('LF_CheckMainThread', [], Fiddle::TYPE_INT)

  LF_CheckApp = bind('LF_CheckApp',
                     [Fiddle::TYPE_VOIDP],
                     Fiddle::TYPE_INT)

  LF_CheckApi = bind('LF_CheckApi',
                     [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                     Fiddle::TYPE_INT)

  # ========================================================================
  # Shutdown (1)
  # ========================================================================

  LF_Shutdown = bind('LF_Shutdown', [], Fiddle::TYPE_VOID)

  # ========================================================================
  # Network events (1)
  # ========================================================================

  LF_Set_Network_Event = bind('LF_Set_Network_Event',
                              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                              Fiddle::TYPE_VOID)

  # ========================================================================
  # String helpers for C ABI calls
  # ========================================================================

  # Converts a Ruby String to a NUL-terminated UTF-8 C string buffer.
  #
  # The returned Fiddle::Pointer is memory-managed by Ruby; it is
  # reclaimed automatically when the pointer object is garbage-collected.
  # The caller must keep the pointer object alive for the duration of
  # the C function call. Do not free it manually.
  #
  # @param value [String, nil]
  # @return [Fiddle::Pointer]
  def self.cstr_ptr(value)
    s = (value || '').to_s.encode('UTF-8')
    ptr = Fiddle::Pointer.malloc(s.bytesize + 1)
    ptr[0, s.bytesize] = s
    ptr[s.bytesize] = 0
    ptr
  end

  # Reads a NUL-terminated UTF-8 string from a raw pointer and returns
  # a Ruby String. Does NOT free the pointer.
  #
  # @param ptr [Fiddle::Pointer, Integer, nil]
  # @return [String]
  def self.read_cstr(ptr)
    return '' if ptr.nil?
    return '' if ptr.respond_to?(:to_i) && ptr.to_i.zero?
    Fiddle::Pointer.new(ptr).to_s.force_encoding('UTF-8')
  end
end