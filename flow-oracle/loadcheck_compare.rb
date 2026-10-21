# frozen_string_literal: true

# Load-verdict parity (WP9, G37): would Remix even START each script, and with which load
# warnings/errors -- versus our Lexer (Lich::Genie::Engine.compile) under the same settings.
#
#   GENIE=remix LICH_WORKTREE=<lich-5> BUNDLE_GEMFILE=<lich-5>/Gemfile \
#     bundle exec ruby loadcheck_compare.rb [--config-dir d | --no-config] <file-or-dir>...
#
# Remix side: `genieflow --loadcheck` (real Script.LoadFile; sandboxed, see README "Write
# sandbox"). Corpus paths (GENIEFLOW_CORPUS_DIRS) get GENIEFLOW_CORPUS_CONFIG, exactly like genieflow.
# Our side: Engine.compile with ignorescriptwarnings from that config dir's settings.cfg
# (GameState::Config.from_settings, the production path) and the glue's include loader
# (ScriptLaunch.locate under the script's own directory). Each file's verdict is
# loaded true/false plus its PrintError lines joined by U+001F (genieflow's format).
# Exit 0 when every verdict matches, 1 otherwise (each difference printed).

require 'json'
require 'open3'
unless defined?(Lich::Genie::Lexer)
  $LOAD_PATH.unshift(File.join(File.expand_path(ENV.fetch('LICH_WORKTREE', File.expand_path('../../lich-5', __dir__))), 'lib'))
  require 'genie'
end

HERE = __dir__
# Optional corpus default, same as genieflow (src/ConfigLoad.cs); unset = Genie defaults.
CORPUS_CONFIG = (c = ENV.fetch('GENIEFLOW_CORPUS_CONFIG', '')).empty? ? nil : c
CORPUS_ROOTS = ENV.fetch('GENIEFLOW_CORPUS_DIRS', '').split(':').reject(&:empty?).map { |r| File.join(File.expand_path(r), '') }.freeze
SEP = [0x1F].pack('U')

args = ARGV.dup
config_dir = nil
no_config = args.delete('--no-config')
if (i = args.index('--config-dir'))
  config_dir = args[i + 1]
  args.slice!(i, 2)
end
abort 'usage: loadcheck_compare.rb [--config-dir d | --no-config] <file-or-dir>...' if args.empty?

paths = args.flat_map { |a| File.directory?(a) ? Dir.glob(File.join(a, '*.cmd')).sort : [a] }.map { |p| File.expand_path(p) }
config_dir ||= CORPUS_CONFIG if CORPUS_CONFIG && !no_config && !CORPUS_ROOTS.empty? && paths.all? { |p| CORPUS_ROOTS.any? { |r| p.start_with?(r) } }

# --- Remix ---
cmd = [File.join(HERE, 'genieflow'), '--loadcheck', *paths]
cmd += config_dir ? ['--config-dir', config_dir] : ['--no-config']
out, err, status = Open3.capture3({ 'GENIE' => ENV.fetch('GENIE', 'remix') }, *cmd)
abort "genieflow --loadcheck failed (#{status.exitstatus}): #{err}" unless status.success?
remix = {}
out.each_line do |line|
  ev = JSON.parse(line)
  remix[File.expand_path(ev['file'])] = [ev['loaded'], ev['errors']] if ev['ev'] == 'loadcheck'
end

# --- ours ---
settings = config_dir ? Lich::Genie::SettingsFile.read(File.join(config_dir, 'settings.cfg')) : []
ignore = Lich::Genie::GameState::Config.from_settings(settings).ignore_script_warnings
ours = {}
paths.each do |path|
  dir = File.dirname(path)
  loader = lambda do |name|
    found = Lich::Genie::ScriptLaunch.locate(dir, name)
    found ? File.binread(found) : nil
  end
  # A zero-byte file goes through the engine like any other: Lexer#compile refuses it with
  # AppendFile's "Unable to load file" (Script.cs:3709, 3775 R; WP9-r1 eng NB3).
  begin
    program = Lich::Genie::Engine.compile(File.binread(path), file_name: File.basename(path), include_loader: loader,
                                                              ignore_warnings: ignore)
    ours[path] = [true, program.messages.join(SEP)]
  rescue Lich::Genie::Lexer::LoadFailed => e
    ours[path] = [false, e.lines.join(SEP)]
  end
end

diffs = paths.reject { |p| remix[p] == ours[p] }
diffs.each do |p|
  puts "DIFF #{p}"
  puts "  remix: #{remix[p].inspect}"
  puts "  ours:  #{ours[p].inspect}"
end
refused = ->(h) { h.values.count { |loaded, _| !loaded } }
warned = ->(h) { h.values.count { |loaded, errors| loaded && !errors.empty? } }
puts "loadcheck: #{paths.length} files, config #{config_dir || '(defaults)'} (ignorescriptwarnings #{ignore}); " \
     "remix refused #{refused.call(remix)} / warned #{warned.call(remix)}, ours refused #{refused.call(ours)} / " \
     "warned #{warned.call(ours)}; #{diffs.length} differences"
exit(diffs.empty? ? 0 : 1)
