# frozen_string_literal: true

# Paths shared by the reference/ tools. Nothing here is machine-specific: everything comes from
# this repository's layout or from environment variables.
#
#   LICH_WORKTREE  the lich-5 checkout under test (the Genie engine branch).
#                  Default: a `lich-5` directory next to this repository.
#   DOTNET         the dotnet executable. Default: $DOTNET_ROOT/dotnet if present, else `dotnet`.
#   CORPUS_DIR     corpus tools only: one or more directories of Genie scripts, separated by ':'.
#                  Each entry is `label=dir` or just `dir` (label = the directory's basename).
#                  The corpus the published results were measured on is private and is NOT part
#                  of this repository (see README.md).
module LabPaths
  ROOT = File.expand_path('..', __dir__)

  module_function

  def lich
    File.expand_path(ENV.fetch('LICH_WORKTREE', File.join(ROOT, '..', 'lich-5')))
  end

  def lich_lib
    File.join(lich, 'lib')
  end

  def dotnet
    d = ENV.fetch('DOTNET', '')
    return d unless d.empty?

    root = ENV.fetch('DOTNET_ROOT', '')
    !root.empty? && File.executable?(File.join(root, 'dotnet')) ? File.join(root, 'dotnet') : 'dotnet'
  end

  def oracle_dll(tree, tfm)
    File.join(ROOT, 'oracle', 'bin', tree, 'Release', tfm, 'genieoracle.dll')
  end

  # @return [Hash{String => String}] label => absolute dir (empty when CORPUS_DIR is unset)
  def corpora
    ENV.fetch('CORPUS_DIR', '').split(':').reject(&:empty?).to_h do |entry|
      label, dir = entry.include?('=') ? entry.split('=', 2) : [File.basename(entry), entry]
      [label, File.expand_path(dir)]
    end
  end

  # Like {corpora}, but aborts with a usage message when CORPUS_DIR is unset or names a missing dir.
  def corpora!
    c = corpora
    abort "#{File.basename($PROGRAM_NAME)}: set CORPUS_DIR to one or more Genie script directories (label=dir or dir, ':'-separated)" if c.empty?
    c.each_value { |d| abort "CORPUS_DIR: no such directory #{d}" unless File.directory?(d) }
    c
  end
end
