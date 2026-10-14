# frozen_string_literal: true
#
# lingofuse.gemspec — Gem metadata for the LingoFuse Ruby binding.
#
# ============================================================================
# IMPORTANT — WHY THE VERSION IS A LITERAL HERE
# ============================================================================
# This file deliberately does NOT `require_relative 'lib/lingofuse'`.
#
# Loading `lib/lingofuse.rb` would trigger the C extension load, which
# resolves the native LingoFuse shared library. That creates a chicken-
# and-egg problem: `bundle install` evaluates the gemspec BEFORE it has
# a chance to install the very dependencies the gemspec needs.
#
# The version string is therefore a literal here, and it is kept in
# sync with `LingoFuse::VERSION` in `lib/lingofuse.rb` by the release
# process. `check_env.rb` reports any drift between the two.
#
# The native LingoFuse shared library is NOT packaged inside this gem.
# It must be installed separately (see TESTING.md). This gem contains
# only the Ruby binding, the C extension source, and the test suite.
#
# ============================================================================
# FFI IS NOT A DEPENDENCY
# ============================================================================
# The v1.x binding used Fiddle (part of the Ruby standard library).
# The v2.x binding replaces Fiddle entirely with the compiled C
# extension `lingofuse_ext.so`, which is loaded by
# lib/lingofuse/native_bridge.rb at require time.
#
# The FFI gem is intentionally NOT listed as a dependency: the FFI
# gem's loader uses LoadLibraryEx with LOAD_WITH_ALTERED_SEARCH_PATH,
# which requires an absolute path and ignores PATH. The C extension
# uses the base LoadLibrary call, which honours PATH — this is the
# entire reason the binding is built on a native extension rather than
# on a pure-Ruby FFI layer.
#
# ============================================================================
# VERSION HISTORY
# ============================================================================
#   1.0.0   Fiddle-based binding. No C extension. Only app-name addressing.
#
#   2.0.0   Fully C-extension based. Adds:
#             - three addressing modes (App / UID / P2PName)
#             - modern async support (CallFuture / AsyncBridge)
#             - 16 typed runtime-option accessors
#             - process-wide P2P registration
#             - UTF-8 tagged string returns from the C boundary
#
# ============================================================================

Gem::Specification.new do |spec|
  spec.name          = 'lingofuse'
  spec.version       = '2.0.0'
  spec.authors       = ['LingoFuse Contributors']
  spec.summary       = 'Ruby binding for the LingoFuse distributed RPC framework'
  spec.description   =
    'Cross-language, cross-process, cross-machine RPC via the LingoFuse ' \
    'C ABI. Provides RAII wrappers for data and application handles, a ' \
    'unified JSON/string/byte I/O layer that is byte-for-byte compatible ' \
    'with the C++, C#, Pascal, Python, JavaScript, and Rust bindings, ' \
    'a process-wide facade for network preparation and remote calls, ' \
    'three orthogonal addressing modes (App name, UID, P2PName), ' \
    'a modern async surface (CallFuture / AsyncBridge) with safe ' \
    'timeout and dispatch-failure semantics, 16 typed runtime-option ' \
    'accessors, and process-wide P2P API registration.'
  spec.homepage      = 'https://github.com/PassByYou888/LingoFuse'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 2.7.0'

  # ---------------------------------------------------------------------------
  # Packaged files
  # ---------------------------------------------------------------------------
  # The globs below automatically pick up every Ruby source file under
  # lib/ and every test file under test/, including the v2.0 additions:
  #
  #     lib/lingofuse/address.rb
  #     lib/lingofuse/async_support.rb
  #     lib/lingofuse/options.rb
  #     lib/lingofuse/p2p_registration.rb
  #
  #     test/test_address.rb
  #     test/test_async_support.rb
  #     test/test_options.rb
  #     test/test_p2p_registration.rb
  #
  # The C extension source (ext/lingofuse_ext/) is included so that a
  # consumer who unpacks the gem has everything needed to build
  # lingofuse_ext.so for their Ruby. The built .so itself is NOT
  # packaged — it is platform- and Ruby-version-specific.
  # ---------------------------------------------------------------------------

  spec.files = Dir['lib/**/*.rb'] +
               Dir['test/**/*.rb'] +
               Dir['ext/lingofuse_ext/*.{c,h,rb}'] +
               %w[
                 check_env.rb
                 check_env.ps1
                 setup_build_env.ps1
                 clean.ps1
                 run_tests.ps1
                 run_test_ci.ps1
                 run_test_ci.sh
                 BUILD_AND_DEPLOY.md
                 INSTALL_DEPENDENCIES.md
                 README.md
                 Rakefile
                 Gemfile
               ]
  spec.require_paths = ['lib']
  spec.extensions    = []   # Manual build; see BUILD_AND_DEPLOY.md

  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'rake', '~> 13.0'
end