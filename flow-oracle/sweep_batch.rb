# frozen_string_literal: true

# Batch differential sweep (the reviewers' scratch batch.rb, made a lab tool): every script given
# runs through diff_driver.rb's run_case (genieflow vs our engine) on one trace, one result block
# per script in OUTFILE. Run sweeps one at a time (sequentially), never in parallel with another
# sweep over the same corpus.
#
#   LICH_WORKTREE=<lich-5 tree> GENIE=remix BUNDLE_GEMFILE=<tree>/Gemfile \
#     bundle exec ruby sweep_batch.rb <trace> <outfile> <script.cmd>...
#   ... sweep_batch.rb <trace> <outfile> @<file listing one script path per line>
#
# Write hygiene (README "Write sandbox"): genieflow writes only into its per-run temp dir and
# diff_driver hands our engine a per-run copy of the config dir; this tool also checks that the
# corpus config dir (GENIEFLOW_CORPUS_CONFIG, if set) and every swept script dir are byte-for-byte unchanged at the end and exits 3
# (printing what changed) if not.
#
# Timeouts: each script gets SWEEP_TIMEOUT seconds (default 60). genieflow runs in its own process
# group (BoundedGenieflow below) and the whole group is killed when the time runs out -- Ruby's
# Timeout alone left the dotnet child running (ww.cmd never ends), still burning a core and
# holding its temp dir.
require 'json'
require 'timeout'
require 'digest'
load File.expand_path('diff_driver.rb', __dir__)

# FlowDiff.run_genie with genieflow in its own process group: whatever ends the call early (the
# per-script Timeout, an interrupt) kills the group -- SIGTERM, then SIGKILL after a grace period.
module BoundedGenieflow
  GRACE_SECONDS = 2

  def run_genie(script, args, trace, scriptdir, gflags = [])
    cmd = [FlowDiff::GENIEFLOW, script, *args, '--json', '--no-in', *gflags]
    cmd += ['--trace', trace] if trace
    cmd += ['--scriptdir', scriptdir] if scriptdir
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn({ 'GENIE' => FlowDiff::GENIE_TREE }, *cmd, out: out_w, err: err_w, pgroup: true)
    out_w.close
    err_w.close
    readers = [out_r, err_r].map { |io| Thread.new { Thread.current.report_on_exception = false; io.read } }
    _, status = Process.wait2(pid)
    pid = nil
    out, err = readers.map(&:value)
    raise "genieflow failed (#{status.exitstatus}): #{err}\n#{out}" unless status.success?

    out.lines.map { |l| JSON.parse(l) }
  ensure
    BoundedGenieflow.kill_group(pid) if pid
    [out_r, err_r].each { |io| io&.close unless io&.closed? }
  end

  # @param pgid [Integer] the group leader's pid (spawned with pgroup: true)
  def self.kill_group(pgid)
    Process.kill('TERM', -pgid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GRACE_SECONDS
    until Process.waitpid(pgid, Process::WNOHANG)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill('KILL', -pgid)
        Process.waitpid(pgid)
        break
      end
      sleep 0.05
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    begin
      Process.kill('KILL', -pgid) # any straggler left in the group
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
FlowDiff.singleton_class.prepend(BoundedGenieflow)

module SweepBatch
  module_function

  TIMEOUT_SECONDS = Float(ENV.fetch('SWEEP_TIMEOUT', '60'))

  # path => sha1 of every file under +dirs+ (no recursion into .git)
  def snapshot(dirs)
    dirs.uniq.select { |d| File.directory?(d) }.each_with_object({}) do |dir, acc|
      Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH).each do |path|
        next if path.include?('/.git/') || !File.file?(path)

        acc[path] = Digest::SHA1.file(path).hexdigest
      end
    end
  end

  def changes(before, after)
    (before.keys | after.keys).sort.reject { |k| before[k] == after[k] }
  end

  def main(argv)
    trace, outfile, *scripts = argv
    abort 'usage: sweep_batch.rb <trace> <outfile> <script.cmd>... | @listfile' if trace.nil? || outfile.nil? || scripts.empty?

    scripts = scripts.flat_map { |s| s.start_with?('@') ? File.readlines(s[1..], chomp: true).reject(&:empty?) : [s] }
    watched = [*FlowDiff::CORPUS_CONFIG, *scripts.map { |s| File.dirname(File.expand_path(s)) }]
    before = snapshot(watched)
    File.open(outfile, 'w') do |out|
      scripts.each do |s|
        begin
          _div, text = Timeout.timeout(TIMEOUT_SECONDS) { FlowDiff.run_case(s, [], trace, File.dirname(s), verbose: false, gflags: []) }
          out.puts text
        rescue Exception => e # rubocop:disable Lint/RescueException -- isolate every script
          out.puts "### #{File.basename(s, '.cmd')}: ERROR #{e.class}: #{e.message[0, 200]}"
        end
        out.flush
      end
    end
    changed = changes(before, snapshot(watched))
    return 0 if changed.empty?

    warn "sweep_batch: FILES CHANGED DURING THE SWEEP (must never happen):\n  #{changed.join("\n  ")}"
    3
  end
end

exit(SweepBatch.main(ARGV.dup)) if $PROGRAM_NAME == __FILE__
