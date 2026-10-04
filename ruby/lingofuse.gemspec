# frozen_string_literal: true
#
# lingofuse.gemspec — Gem metadata for the LingoFuse Ruby binding.
#
# ============================================================================
# IMPORTANT — WHY THE VERSION IS A LITERAL HERE
# ============================================================================
# This file deliberately does NOT `require_relative 'lib/lingofuse'`.
#
# Loading `lib/lingofuse.rb` would trigger `binding.rb`, which loads the
# native LingoFuse shared library. That creates a chicken-and-egg
# problem: `bundle install` evaluates the gemspec BEFORE it has a chance
# to install the very dependencies the gemspec needs.
#
# The version string is therefore a literal here, and it is kept in
# sync with `LingoFuse::VERSION` in `lib/lingofuse.rb` by the release
# process. `check_env.rb` reports any drift between the two.
#
# The native LingoFuse shared library is NOT packaged inside this gem.
# It must be installed separately (see TESTING.md). This gem contains
# only the Ruby binding, the unified I/O helper, and the test suite.
#
# ============================================================================
# FFI IS NOT A DEPENDENCY
# ============================================================================
# This binding uses Fiddle, which is part of the Ruby standard library.
# The FFI gem is intentionally NOT listed as a dependency: the FFI gem's
# loader uses LoadLibraryEx with LOAD_WITH_ALTERED_SEARCH_PATH, which
# requires an absolute path and ignores PATH. Fiddle uses the base
# LoadLibrary call, which honours PATH — this is the entire reason the
# binding is built on Fiddle.
# ============================================================================

Gem::Specification.new do |spec|
  spec.name          = 'lingofuse'
  spec.version       = '1.0.0'
  spec.authors       = ['LingoFuse Contributors']
  spec.summary       = 'Ruby binding for the LingoFuse distributed RPC framework'
  spec.description   =
    'Cross-language, cross-process, cross-machine RPC via the LingoFuse ' \
    'C ABI. Provides RAII wrappers for data and application handles, a ' \
    'unified JSON/string/byte I/O layer that is byte-for-byte compatible ' \
    'with the C++, C#, Pascal, Python, JavaScript, and Rust bindings, ' \
    'and a process-wide facade for network preparation and remote calls.'
  spec.homepage      = 'https://github.com/PassByYou888/LingoFuse'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 2.7.0'

  spec.files = Dir['lib/**/*.rb'] +
               Dir['test/**/*.rb'] +
               %w[check_env.rb run_tests.ps1 TESTING.md Rakefile Gemfile]
  spec.require_paths = ['lib']

  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'rake', '~> 13.0'
end