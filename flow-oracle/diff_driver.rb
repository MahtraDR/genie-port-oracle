# frozen_string_literal: true

# FLOW DIFF DRIVER: run the same .cmd + trace through
#   (A) genieflow  -- Genie4's REAL Script.cs/Command.cs/Game.cs/Globals.cs (headless, virtual clock)
#   (B) OUR engine -- $LICH_WORKTREE/lib/genie (a lich-5 checkout), driven headless on the same
#       virtual clock with fake ports (Fiber per script, 10 ms ticks)
# and diff the observable event streams (sends, echoes, errors, global var sets) incl. timing.
#
#   ruby diff_driver.rb <script.cmd> [args...] [--trace file] [--scriptdir dir] [--verbose]
#   ruby diff_driver.rb --all tests/            # every tests/*.cmd (+ same-name .trace/.args/.flags/.only)
#
# Genie tree: env GENIE=remix (default; Genie4 Remix v4.2.4, the parity target) | GENIE=upstream
# (Genie4 4.5.0.3). Runtime: env GENIE_TFM=net10.0 (default) | net8.0, passed through to ./genieflow. Extra genieflow-only options: --config-dir DIR, --no-config,
# --trigger-delivery row|chunk|sync (passed to genieflow; our side only honours the config dir).
# Any other option in a .flags file raises (Flow.parse_flags), it is never silently ignored.
#
# Trace language (shared with genieflow, see README.md): IN/PROMPT/ROOM/FLUSH/TICK/WAIT/EXPECT/
# VAR/INPUT/RUN/IDLE. How each directive reaches OUR engine (modelling the Lich glue,
# lib/genie/genie_script.rb):
#   IN <text>   -> stripped by Lich's real strip_xml, pushed to every running script's input (Lich
#                  downstream) and offered to global #triggers (genie-downstream hook). This is the
#                  LICH filter (SUPPRESSED_STREAMS), not Remix's stream routing (N19, t52)
#   PROMPT [rt] -> nothing reaches the interpreter (Lich strip_xml drops <prompt>); rt sets a
#                  virtual roundtime that our LichGamePort-equivalent send waits out (waitrt?)
#   ROOM        -> nothing reaches the interpreter (component XML is stripped)
#   INPUT text  -> user typing as Remix Command.ParseCommand(sText, true, true) (FormMain.cs:4216 R):
#                  ;/bug/sing rows sent whole, else split on `;`; `$`globals expanded except in
#                  raw-storing #arms (#trigger, #alias, ...); see the harness header
#   Directive clock = genieflow's chunk model (IN/PROMPT/ROOM open a chunk, see the harness)
# The our-engine side is spec/lib/genie/support/flow_harness.rb in the lich-5 worktree
# (env LICH_WORKTREE overrides the path); the rspec ratchet runs the same code.
#
# Exit 0 = no divergences in any compared stream.

require 'json'
require 'fiber'
require 'open3'
require 'tmpdir'
require 'fileutils'

# The lich-5 checkout under test (the Genie engine PR branch). Default: a `lich-5` directory next
# to this repository's checkout.
LICH = File.expand_path(ENV.fetch('LICH_WORKTREE', File.expand_path('../../lich-5', __dir__)))
HARNESS = File.join(LICH, 'spec/lib/genie/support/flow_harness.rb')
abort "diff_driver: no flow harness at #{HARNESS}: set LICH_WORKTREE to a lich-5 checkout of the Genie engine branch" unless File.exist?(HARNESS)
$LOAD_PATH.unshift(File.join(LICH, 'lib'))
require 'genie'
require HARNESS

module FlowDiff
  GENIEFLOW = File.expand_path('genieflow', __dir__)
  GENIE_TREE = ENV.fetch('GENIE', 'remix')
  # Same optional default as genieflow (src/ConfigLoad.cs): with GENIEFLOW_CORPUS_DIRS (':'-separated
  # dirs) and GENIEFLOW_CORPUS_CONFIG (a Genie Config dir) both set, scripts under those dirs get that
  # Config dir unless --config-dir / --no-config is given. Unset (the default): Genie defaults.
  CORPUS_CONFIG = (c = ENV.fetch('GENIEFLOW_CORPUS_CONFIG', '')).empty? ? nil : c
  CORPUS_ROOTS = ENV.fetch('GENIEFLOW_CORPUS_DIRS', '').split(':').reject(&:empty?).map { |r| File.join(File.expand_path(r), '') }.freeze

  # The config dir genieflow will load for this run (nil = Genie defaults).
  def self.effective_config_dir(script, gflags)
    return nil if gflags.include?('--no-config')
    if (i = gflags.index('--config-dir')) then return gflags[i + 1] end
    full = File.expand_path(script)
    CORPUS_CONFIG && CORPUS_ROOTS.any? { |r| full.start_with?(r) } ? CORPUS_CONFIG : nil
  end
  abort "GENIE must be remix|upstream (got #{GENIE_TREE})" unless %w[remix upstream].include?(GENIE_TREE)

  # ------------------------------------------------------------------ (A) genieflow
  def self.run_genie(script, args, trace, scriptdir, gflags = [])
    cmd = [GENIEFLOW, script, *args, '--json', '--no-in', *gflags]
    cmd += ['--trace', trace] if trace
    cmd += ['--scriptdir', scriptdir] if scriptdir
    out, err, st = Open3.capture3({ 'GENIE' => GENIE_TREE }, *cmd)
    raise "genieflow failed (#{st.exitstatus}): #{err}\n#{out}" unless st.success?

    out.lines.map { |l| JSON.parse(l) }
  end

  # ------------------------------------------------------------------ (B) our engine + diff
  # The our-engine side (OurRun, trace parsing, stream projection, LCS alignment, timing
  # tolerance) lives in the lich-5 worktree as the rspec flow-parity harness, so this
  # differential and spec/lib/genie/flow_parity_spec.rb share ONE implementation:
  #   $LICH_WORKTREE/spec/lib/genie/support/flow_harness.rb (default worktree above)
  # Its header documents every modelling assumption (IN/PROMPT/ROOM delivery, RT prescan,
  # INPUT expansion/splitting, chunk clock, integer-ms clock + near-expiry wait model, 60 ms
  # tolerance; script lifecycle (script-finish) is NOT compared, only sends/echoes/errors/vars).
  Flow = GenieSpecSupport::Flow
  TIMING_TOLERANCE_MS = Flow::TIMING_TOLERANCE_MS

  def self.parse_trace(path) = Flow.parse_trace(path)
  def self.compare(genie_events, our_events) = Flow.compare(genie_events, our_events)
  def self.divergent?(report) = Flow.divergent?(report)
  def self.format_report(name, report) = Flow.format_report(name, report)

  # Fixtures (run_ours / the rspec ratchet) RAISE on a config dir holding files our side does not
  # load (Flow.check_config_dir). Here (explicit --config-dir, or a corpus default config dir with
  # aliases.cfg + settings.cfg) genieflow loads them and ours only loads variables.cfg, so the diff
  # is NOT like with like: say so on stderr instead of silently comparing.
  def self.warn_unmodelled_config(dir)
    return unless dir && File.directory?(dir)

    ignored = (Flow::GENIEFLOW_CONFIG_FILES - Flow::MODELLED_CONFIG_FILES).select { |f| File.exist?(File.join(dir, f)) }.sort
    warn "diff_driver: WARNING #{dir} holds #{ignored.join(' ')}: genieflow loads them, our side ignores them" unless ignored.empty?
  end

  # Our side reads the config dir from a private per-run copy too (genieflow: src/ShimsIO.cs
  # Sandbox), so nothing a run does can reach the real dir (README "Write sandbox").
  def self.with_config_copy(dir)
    return yield(nil) unless dir

    Dir.mktmpdir('diff_driver-config') do |tmp|
      Dir.children(dir).each do |f|
        src = File.join(dir, f)
        FileUtils.cp(src, File.join(tmp, f)) if File.file?(src)
      end
      yield tmp
    end
  end

  def self.run_case(script, args, trace, scriptdir, verbose: false, gflags: [])
    scriptdir ||= File.dirname(File.expand_path(script))
    name = File.basename(script, '.cmd')
    Flow.parse_flags(gflags) # raise on an option our side cannot honour, before running genieflow
    # A relative .flags --config-dir is relative to the test dir (run_tests.sh runs from
    # there; Flow.run_ours resolves it the same way), not to our cwd.
    if (ci = gflags.index('--config-dir')) && gflags[ci + 1]
      gflags = gflags.dup
      gflags[ci + 1] = File.expand_path(gflags[ci + 1], File.dirname(File.expand_path(script)))
    end
    config_dir = effective_config_dir(script, gflags)
    warn_unmodelled_config(config_dir)
    genie = run_genie(script, args, trace, scriptdir, gflags) # genieflow loads its own private copy
    ours = with_config_copy(config_dir) do |copy|
      Flow::OurRun.new(scriptdir, config_dir: copy).run(name, args, parse_trace(trace)).events
    end
    report = compare(genie, ours)
    text = format_report(name + (args.empty? ? '' : " #{args.join(' ')}") + (gflags.empty? ? '' : " [#{gflags.join(' ')}]"), report)
    if verbose
      text += "\n  --- genie events\n" + genie.map { |e| "    #{e.to_json}" }.join("\n")
      text += "\n  --- our events\n" + ours.map { |e| "    #{e.to_json}" }.join("\n")
    end
    [divergent?(report), text]
  end

  def self.main(argv)
    verbose = argv.delete('--verbose')
    if (i = argv.index('--all'))
      dir = argv[i + 1] || File.expand_path('tests', __dir__)
      any = false
      counts = Hash.new(0)
      Dir.glob(File.join(dir, '*.cmd')).sort.each do |cmd|
        base = cmd.sub(/\.cmd\z/, '')
        next if File.basename(base).start_with?('_') # include-only helpers

        next if File.exist?("#{base}.only") && File.read("#{base}.only").strip != GENIE_TREE

        trace = File.exist?("#{base}.trace") ? "#{base}.trace" : nil
        args = File.exist?("#{base}.args") ? File.read("#{base}.args").split : []
        gflags = File.exist?("#{base}.flags") ? File.read("#{base}.flags").split : []
        div, text = run_case(cmd, args, trace, dir, verbose: verbose, gflags: gflags)
        any ||= div
        counts[div ? :divergent : :ok] += 1
        puts text
      end
      warn "diff_driver: #{counts[:ok]} of #{counts[:ok] + counts[:divergent]} MATCH, #{counts[:divergent]} DIVERGENT"
      return any ? 1 : 0
    end
    trace = (j = argv.index('--trace')) ? argv.slice!(j, 2)[1] : nil
    scriptdir = (j = argv.index('--scriptdir')) ? argv.slice!(j, 2)[1] : nil
    gflags = []
    %w[--config-dir --trigger-delivery].each { |f| (j = argv.index(f)) && gflags.concat(argv.slice!(j, 2)) }
    gflags << argv.delete('--no-config') if argv.include?('--no-config')
    script, *args = argv
    abort 'usage: [GENIE=remix|upstream] ruby diff_driver.rb <script.cmd> [args] [--trace t] [--scriptdir d] [--config-dir d|--no-config] [--trigger-delivery m] [--verbose] | --all dir' unless script
    div, text = run_case(script, args, trace, scriptdir, verbose: verbose, gflags: gflags)
    puts text
    div ? 1 : 0
  end
end

exit(FlowDiff.main(ARGV.dup)) if $PROGRAM_NAME == __FILE__
