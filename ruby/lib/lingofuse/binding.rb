# frozen_string_literal: true
#
# binding.rb — Low-level Fiddle declarations for the LingoFuse C ABI.
#
# This module is the ONLY place in the Ruby binding where native code is
# invoked. It uses Ruby's standard-library Fiddle (not the FFI gem).
#
# ============================================================================
# NATIVE LIBRARY DISCOVERY
# ============================================================================
# The LingoFuse native shared library (and its dependent DLLs / shared
# objects) is resolved EXCLUSIVELY through the operating system's library
# search path. There is no binding-relative directory walking, no
# hard-coded path, and no binding-specific environment variable.
#
# The search path is taken from the platform's standard environment
# variables:
#
#   Windows           PATH                              (semicolon-separated)
#   Linux / BSD       LD_LIBRARY_PATH                   (colon-separated)
#   macOS             DYLD_LIBRARY_PATH                 (colon-separated)
#                     DYLD_FALLBACK_LIBRARY_PATH
#
# This makes the binding fully portable: copy the ruby/ tree anywhere, and
# as long as the directory that contains the native library is on the
# system search path, it loads. There is no per-project configuration and
# no relative directory resolution.
#
# If the library is not found in any directory on the search path, the
# bare file name is handed to Fiddle.dlopen, which delegates to the OS
# loader's own default search (system directories, /etc/ld.so.conf,
# @rpath, standard framework paths).
#
# On Windows, once the directory containing the library is located, that
# directory is registered with SetDllDirectoryW so that the library's own
# dependencies (z_ipc_64.dll, mimalloc64.dll, mimalloc-redirect.dll) are
# resolved from the same directory. This reflects the runtime contract
# that the four DLLs must always live together.
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
  # System library search path
  # ========================================================================

  # Returns the ordered, de-duplicated list of directories that make up
  # the operating system's library search path for the current platform.
  #
  # Only the standard environment variables are consulted:
  #
  #   Windows           PATH
  #   Linux / BSD       LD_LIBRARY_PATH
  #   macOS             DYLD_LIBRARY_PATH
  #                     DYLD_FALLBACK_LIBRARY_PATH
  #
  # Empty entries are dropped. Duplicates are removed while preserving
  # first-occurrence order, so callers can search deterministically.
  #
  # @return [Array<String>]
  def self.system_library_search_dirs
    os = RbConfig::CONFIG['host_os'].to_s

    raw_values =
      if os =~ /mswin|mingw|cygwin/i
        [ENV['PATH']]
      elsif os =~ /darwin/i
        [ENV['DYLD_LIBRARY_PATH'], ENV['DYLD_FALLBACK_LIBRARY_PATH']]
      else
        [ENV['LD_LIBRARY_PATH']]
      end

    separator = (os =~ /mswin|mingw|cygwin/i) ? ';' : ':'

    dirs = []
    seen = {}

    raw_values.each do |raw|
      next if raw.nil? || raw.empty?

      raw.split(separator).each do |entry|
        dir = entry.strip
        next if dir.empty?
        next if seen[dir]
        seen[dir] = true
        dirs << dir
      end
    end

    dirs
  end

  # ========================================================================
  # Library search
  # ========================================================================

  # Searches the system library search path for `lib_name` and returns
  # the absolute path of the first directory that contains it, or nil
  # when no directory on the search path contains the file.
  #
  # @param lib_name [String] platform-specific library file name
  # @return [String, nil] absolute path to the library file
  def self.find_library_on_system_path(lib_name)
    system_library_search_dirs.each do |dir|
      candidate = File.join(dir, lib_name)
      begin
        return candidate if File.file?(candidate)
      rescue StandardError
        # A malformed search-path entry (invalid encoding, permission
        # denied, unmounted network share) must not abort the search.
        # Skip it and continue with the remaining directories.
        next
      end
    end
    nil
  end

  # ========================================================================
  # Windows dependency directory registration
  # ========================================================================

  # Registers a directory with SetDllDirectoryW so that subsequent
  # LoadLibrary calls resolve dependent DLLs (z_ipc_64.dll,
  # mimalloc64.dll, mimalloc-redirect.dll) from that directory as well.
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

  # Loads the native LingoFuse shared library by scanning the operating
  # system's library search path.
  #
  # Resolution strategy:
  #
  #   1. Enumerate the system library search path
  #      (PATH on Windows, LD_LIBRARY_PATH on Linux / BSD,
  #       DYLD_LIBRARY_PATH + DYLD_FALLBACK_LIBRARY_PATH on macOS).
  #
  #   2. For each directory, look for the exact library file name. The
  #      first directory that contains it wins. On Windows, that
  #      directory is registered with SetDllDirectoryW before the load,
  #      so the library's own dependencies resolve from the same
  #      directory.
  #
  #   3. If no directory on the search path contains the file, hand the
  #      bare name to Fiddle.dlopen. This delegates to the OS loader's
  #      own default search, which covers system directories,
  #      /etc/ld.so.conf on Linux, and @rpath on macOS.
  #
  # There is no binding-relative search and no binding-specific
  # environment variable. Portability comes from the system path alone.
  #
  # @param lib_name [String]
  # @return [Object] the Fiddle library handle
  # @raise [LibraryLoadError] when the library cannot be loaded
  def self.load_native_library(lib_name)
    errors = []

    # --- Step 1: search the system library search path ------------------
    system_library_search_dirs.each do |dir|
      candidate = File.join(dir, lib_name)

      begin
        next unless File.file?(candidate)
      rescue StandardError
        next
      end

      begin
        register_dll_directory(dir)
        return Fiddle.dlopen(candidate)
      rescue Fiddle::DLError => e
        errors << "#{candidate}: #{e.message}"
      end
    end

    # --- Step 2: hand the bare name to the OS loader --------------------
    # This covers the platform's own default search: Windows system
    # directories, Linux /etc/ld.so.conf and RPATH, macOS @rpath and
    # standard framework paths.
    begin
      return Fiddle.dlopen(lib_name)
    rescue Fiddle::DLError => e
      errors << "#{lib_name} (via OS loader): #{e.message}"
    end

    raise LibraryLoadError, build_load_error_message(lib_name, errors)
  end

  # Builds a clear, actionable error message listing every attempt.
  #
  # @param lib_name [String]
  # @param errors [Array<String>]
  # @return [String]
  def self.build_load_error_message(lib_name, errors)
    os = RbConfig::CONFIG['host_os'].to_s

    path_var =
      if os =~ /mswin|mingw|cygwin/i
        'PATH'
      elsif os =~ /darwin/i
        'DYLD_LIBRARY_PATH / DYLD_FALLBACK_LIBRARY_PATH'
      else
        'LD_LIBRARY_PATH'
      end

    lines = []
    lines << "Failed to load the LingoFuse native library '#{lib_name}'."
    lines << ''
    lines << 'The library is resolved exclusively through the operating'
    lines << "system's library search path (#{path_var})."
    lines << ''
    lines << 'Attempts:'
    if errors.empty?
      lines << '  (no directory on the search path contained the library,'
      lines << '   and the OS loader fallback also failed)'
    else
      errors.each { |e| lines << "  - #{e}" }
    end
    lines << ''
    lines << 'To make the library discoverable, add the directory that'
    lines << "contains it to #{path_var}."
    lines << ''

    if os =~ /mswin|mingw|cygwin/i
      lines << 'On Windows, the following files must all live in the SAME'
      lines << 'directory, because LingoFuse64.dll loads its siblings by'
      lines << 'name:'
      lines << '    LingoFuse64.dll'
      lines << '    z_ipc_64.dll'
      lines << '    mimalloc64.dll'
      lines << '    mimalloc-redirect.dll'
      lines << ''
      lines << 'Example (PowerShell, current session):'
      lines << '    $env:PATH = "D:\LingoFuse\Binary;" + $env:PATH'
    elsif os =~ /darwin/i
      lines << 'Example (bash / zsh):'
      lines << '    export DYLD_LIBRARY_PATH="/opt/lingofuse/lib:$DYLD_LIBRARY_PATH"'
    else
      lines << 'Example (bash / zsh):'
      lines << '    export LD_LIBRARY_PATH="/opt/lingofuse/lib:$LD_LIBRARY_PATH"'
    end

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