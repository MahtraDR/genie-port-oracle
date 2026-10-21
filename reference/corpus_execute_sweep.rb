# frozen_string_literal: true

# CORPUS EXECUTE-SWEEP (runtime robustness harness).
#
# Sibling to corpus_sweep.rb (which only COMPILES every corpus .cmd). This one
# actually RUNS each script headless against a synthetic/empty game stream and
# catches runtime failures: escaped Ruby exceptions (BUGS), the engine's own
# runaway guards firing (EXPECTED for combat/loop scripts fed an empty stream),
# input-exhaustion (a script that waits forever with no more input -- EXPECTED),
# and true hangs (our outer thread-kill safety net -- noted).
#
# This is NOT a parity test. Its only job is to surface CRASHES / robustness gaps.
#
# Run:  CORPUS_DIR=label=dir[:label=dir...] ruby reference/corpus_execute_sweep.rb
# Env:  LICH_WORKTREE=dir  engine tree to load (default: ../lich-5 next to this repository;
#                         point it at a `git worktree add` of HEAD to sweep the committed engine)
#       SWEEP_OUT=prefix  write <prefix>.log.jsonl / <prefix>.summary.txt instead of the defaults
#       DUMP_SENDS=1  also log every script's sent commands (use with ONLY=)
#       LIMIT=N       cap scripts per corpus (smoke test)
#       ONLY=substr   only run scripts whose path includes substr
#       OUTER=12.0    outer per-script wall-clock kill (seconds, real time)
#
# Every result also carries `echo_text` (the script's echo lines, first ECHO_TEXT_CAP),
# `window_echo_text` (each `#echo >window text` hook as ">window text"; not counted in
# `echoes`) and `echo_sha` / `window_echo_sha` / `send_sha` (SHA1 of ALL of them), so two
# sweeps can be compared on
# what was echoed and sent, not only on counts (a payload change at the same count -- e.g.
# `#echo #hex text` losing its text -- is invisible to counts; WP4-r1 engineering NB8).
# Compare two logs with corpus_execute_compare.rb.
#
# Writes a per-script JSONL log + a human summary to reference/ (or SWEEP_OUT) and
# NOTHING else: it loads no Genie config dir (no variables.cfg / settings.cfg), each script's
# store is a file-less GlobalStore, `#trigger save` & co. go to a recording hook sink, launches
# are recorded, not run -- so no sweep can write into the corpus or a tester's config (lab write
# hygiene, flow-oracle README "Write sandbox", 2026-10-20). Keep it that way.

require_relative 'lab_paths'
$LOAD_PATH.unshift(LabPaths.lich_lib)
require 'genie'
require 'json'
require 'digest'
include Lich::Genie

CORPORA = LabPaths.corpora!.freeze # CORPUS_DIR=label=dir:label=dir...

OUTER_TIMEOUT = (ENV['OUTER'] || '12.0').to_f # real-time safety net per script
NIL_CAP       = 3000  # synthetic-EOF: raise after this many timeout-nils in a wait
LINE_BUDGET   = 60    # synthetic lines to feed (exercises match/regex paths) before nil-only
ECHO_TEXT_CAP = 200   # echo lines kept per script in the log (the sha covers all of them)

SWEEP_OUT    = ENV['SWEEP_OUT'] || File.join(__dir__, 'corpus_execute_sweep')
LOG_PATH     = "#{SWEEP_OUT}.log.jsonl"
SUMMARY_PATH = "#{SWEEP_OUT}.summary.txt"

# A wait that never gets a matching line: our synthetic EOF. Distinct class so the
# harness never mistakes it for an engine crash. Mirrors interpreter_spec's FakeInput,
# which raises after 1000 nils ("input exhausted (script waited with no more input)").
class SweepInputExhausted < StandardError; end

# Records sends; never blocks (no waitrt?, no put). Models FakeGame in the specs.
class FakeGame
  attr_reader :commands

  def initialize
    @commands = []
  end

  def send_command(text)
    @commands << text
  end
end

# Feeds a fixed pool of synthetic game lines for the first LINE_BUDGET reads (so
# match/matchre/waitforre actually COMPILE and run their regexes -- the only way to
# surface a RegexpError from a corpus pattern), then returns nil (timeout) while
# advancing the shared fake-clock accumulator so timed waits (pause/delay/matchwait N)
# resolve fast. After NIL_CAP consecutive dead reads it raises SweepInputExhausted so
# an UNTIMED matchwait/waitfor/wait on an empty stream terminates deterministically
# instead of spinning until the outer kill.
class FakeInput
  POOL = [
    'You attack a goblin.',
    'A goblin swings a scimitar at you and misses.',
    'Roundtime: 3 sec.',
    '...wait 2 seconds.',
    'You have recovered.',
    'The goblin falls to the ground motionless.',
    'You are now standing.',
    'Your mind is clear.',
    'YOU HAVE ARRIVED',
    'Obvious exits: north, east, out.',
    '',
    'A goblin is dead.'
  ].freeze

  # Engines from v0.18.0 (WP6) read the game's script-timing events (Lich::Genie::GameEvents)
  # and resume a wait only at the end of a DR packet: there every pool line is its own packet
  # -- the line, then the prompt that ends every DR packet (`> `, offered like a game line) --
  # and the `Obvious exits` line comes with the room desc's TriggerMove before it. Older engines
  # get the bare lines (they resumed on any line). LINE_BUDGET counts pool lines.
  # @return [Array<Array>, nil] one packet (item list) per POOL line; nil for an older engine
  def self.packets
    return nil unless defined?(Lich::Genie::GameEvents)

    POOL.map do |line|
      room = line.start_with?('Obvious exits') ? [Lich::Genie::GameEvents::MOVE] : []
      [*room, line, Lich::Genie::GameEvents::Prompt.new('> ')]
    end
  end

  def initialize(clock_acc)
    @clock_acc = clock_acc
    @served = 0
    @nils = 0
    @packets = self.class.packets
    @pending = []
  end

  def next_line(timeout: nil)
    return @pending.shift unless @pending.empty?

    if @served < LINE_BUDGET
      index = @served % POOL.length
      @served += 1
      return POOL[index] unless @packets

      first, *rest = @packets[index]
      @pending.concat(rest)
      return first
    end
    @nils += 1
    raise SweepInputExhausted, "waited with no matching input (#{@nils} dead reads)" if @nils > NIL_CAP

    # Advance virtual time so timed waits resolve; a bare (untimed) wait falls through
    # to the NIL_CAP guard above.
    @clock_acc[0] += (timeout && timeout.positive? ? timeout : 1.0)
    nil
  end
end

# Resolve includes exactly like corpus_sweep.rb: glob the corpus dir (and subdirs)
# for <name>, <name>.cmd, <name>.inc.
def loader_for(dir)
  lambda do |name|
    cand = name.include?('.') ? [name] : [name, "#{name}.cmd", "#{name}.inc"]
    cand.each do |c|
      hit = Dir.glob("#{dir}/**/#{c}").reject { |p| p.include?('/.git/') }.first
      return File.read(hit) if hit
    end
    nil
  end
end

# T03: the old single GUARD_TRIP class mixed two different guards. Split them:
#   GUARD_SCRIPTTIMEOUT -- our port of Genie's scripttimeout watchdog (a row loop with no
#     wait/send for 5 s; Remix Script.cs:1819-1830 R, the tester's scripttimeout 5000). PARITY:
#     the script would be stopped natively too.
#   GUARD_SENDLOOP -- our send-history loop guard (interpreter.rb). Remix has NO such guard
#     (Script.cs:4438-4441 R, finding N01, user decision D2: delete it). The guard was REMOVED in
#     lich-5 genie v0.11.0 (WPR); the bucket stays only to catch a regression and must stay 0.
#   ENGINE_MSG -- finished, but our engine printed a `[`-diagnostic (unknown label, bad
#     RETURN, ...): not a crash, but worth a look (often a G36/G37 parity gap).
TIMEOUT_GUARD_RE = /\A\[Script timeout in .*Possible infinite loop/i
SEND_GUARD_RE = /\A\[Script error: possible infinite loop detected/i
ENGINE_MSG_RE = /\A\[(Script |Genie|Unknown label|RETURN|Invalid|Maximum GOSUB|Javascript)/
#   LOAD_FAILED -- (v0.22.0+, WP9 G37) the engine refused to LOAD the script the way Remix does
#     (Lexer::LoadFailed: an include the sweep's loader cannot find, an invalid IF/WHILE, ...);
#     its script error lines are the echoes. PARITY, not a crash.
OUTCOMES = %w[CLEAN ENGINE_MSG GUARD_SCRIPTTIMEOUT GUARD_SENDLOOP INPUT_EXHAUSTED TIMEOUT LOAD_FAILED EXCEPTION].freeze

# Run one script fully isolated in its own thread with a hard outer kill. Returns a
# result Hash. The fake clock combines REAL monotonic time (so the engine's real
# runaway guard -- the 5s scripttimeout (the send-history guard is gone) -- fires authentically for
# pure-goto/send loops) PLUS a fake accumulator the input port advances (so timed
# waits resolve instantly with no real sleeping).
# The text fields every non-exception result carries (see the header).
def text_fields(echoes, sends, window_echoes)
  { echo_text: echoes.first(ECHO_TEXT_CAP).map(&:to_s), echo_sha: Digest::SHA1.hexdigest(echoes.map(&:to_s).join("\n")),
    window_echo_text: window_echoes.first(ECHO_TEXT_CAP), window_echo_sha: Digest::SHA1.hexdigest(window_echoes.join("\n")),
    send_sha: Digest::SHA1.hexdigest(sends.map(&:to_s).join("\n")) }
end

# The hook sink: keeps only `#echo >window` effects (as ">window text").
def window_echo_sink(window_echoes)
  Object.new.tap do |o|
    o.define_singleton_method(:emit) do |op, payload|
      window_echoes << ">#{payload['window']} #{payload['text']}" if op == 'echo' && payload.is_a?(Hash)
    end
  end
end

def execute_one(path, loader)
  src = File.read(path)
  echoes = []
  window_echoes = []
  base = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  clock_acc = [0.0]
  clock = -> { (Process.clock_gettime(Process::CLOCK_MONOTONIC) - base) + clock_acc[0] }

  captured = nil
  game = FakeGame.new
  # v0.17.0+ (WP4): `send` / `#send` / `-N` fill a timed CommandQueue that the glue's worker
  # drains; here the queue is released after the run (RunQueueCommand through a global-scope
  # TriggerRunner, the fake clock stepped past each delay), so `sends` counts what would reach
  # the game. Older engines have no queue port.
  queue = defined?(Lich::Genie::CommandQueue) ? Lich::Genie::CommandQueue.new(clock: -> { Time.at(clock.call) }) : nil
  ports = queue ? { queue: queue } : {}
  thread = Thread.new do
    Thread.current.report_on_exception = false
    begin
      interp = Engine.build(
        src,
        name: File.basename(path, File.extname(path)),
        ignore_warnings: true,
        include_loader: loader,
        game: game,
        input: FakeInput.new(clock_acc),
        echo: ->(text) { echoes << text },
        hooks: window_echo_sink(window_echoes),
        launch: ->(_name, _args) {},           # do NOT actually spawn other scripts
        mover: ->(_room) {},
        clock: clock,
        **ports
      )
      begin
        interp.run
      ensure
        release_queue(queue, game, clock_acc, echoes, window_echoes) if queue
      end
    rescue Exception => e # rubocop:disable Lint/RescueException -- isolate EVERYTHING per script
      captured = e
    end
  end

  finished = thread.join(OUTER_TIMEOUT)
  unless finished
    thread.kill
    thread.join(2)
    return { path: path, outcome: 'TIMEOUT', echoes: echoes.length, sends: game.commands.length }.merge(text_fields(echoes, game.commands, window_echoes))
  end

  if captured.nil?
    msgs = echoes.grep(ENGINE_MSG_RE)
    outcome = if echoes.any? { |e| e =~ SEND_GUARD_RE } then 'GUARD_SENDLOOP'
              elsif echoes.any? { |e| e =~ TIMEOUT_GUARD_RE } then 'GUARD_SCRIPTTIMEOUT'
              elsif msgs.any? then 'ENGINE_MSG'
              else 'CLEAN'
              end
    res = { path: path, outcome: outcome, echoes: echoes.length, sends: game.commands.length,
            engine_msgs: msgs.first(3) }.merge(text_fields(echoes, game.commands, window_echoes))
    res[:commands] = game.commands if ENV['DUMP_SENDS']
    return res
  end

  if captured.is_a?(SweepInputExhausted)
    res = { path: path, outcome: 'INPUT_EXHAUSTED', echoes: echoes.length, sends: game.commands.length }
          .merge(text_fields(echoes, game.commands, window_echoes))
    res[:commands] = game.commands if ENV['DUMP_SENDS']
    return res
  end

  if defined?(Lich::Genie::Lexer::LoadFailed) && captured.is_a?(Lich::Genie::Lexer::LoadFailed)
    return { path: path, outcome: 'LOAD_FAILED', echoes: echoes.length, sends: game.commands.length,
             engine_msgs: captured.lines.first(3) }.merge(text_fields(echoes, game.commands, window_echoes))
  end

  # A real crash escaped the engine -- a BUG (unless it's malformed-in-Genie too).
  frames = captured.backtrace || []
  genie_frames = frames.select { |f| f.include?('/lib/genie/') }
  {
    path: path,
    outcome: 'EXCEPTION',
    error_class: captured.class.name,
    error_message: captured.message.to_s[0, 300],
    backtrace_top: frames.first(4),
    genie_frames: genie_frames.first(4)
  }
end

# Release every queued command (bounded), like the glue's CommandQueue::Worker would. Its
# echoes and `#echo >window` effects are logged like the script's own (a queued `send #echo`
# echoes after the run here; production echoes it on the next 10 ms tick).
def release_queue(queue, game, clock_acc, echoes, window_echoes)
  vars = Variables.new
  globals = Object.new.tap { |o| o.define_singleton_method(:key?) { |n| vars.global_key?(n) } }
  runner = TriggerRunner.new(vars: vars, eval: Eval.new(globals: globals), game: game, launch: ->(_n, _a) {},
                             hooks: window_echo_sink(window_echoes), echo: ->(text) { echoes << text }, queue: queue)
  20_000.times do
    break if queue.empty?

    queue.drain(-> { CommandQueue::FREE }) { |action| runner.run_command(action) }
    clock_acc[0] += 0.01
  end
rescue StandardError
  nil
end

def enumerate(dir)
  Dir.glob("#{dir}/**/*.{cmd,Cmd,CMD}")
     .reject { |p| p.include?('/.git/') }
     .reject { |p| File.basename(p) =~ /notes|todo|readme|read.?me/i }
     .reject { |p| p.end_with?('.js') }
     .sort
end

# --- driver ---------------------------------------------------------------

only  = ENV['ONLY']
limit = ENV['LIMIT'] ? ENV['LIMIT'].to_i : nil

log = File.open(LOG_PATH, 'w')
log.sync = true

grand = Hash.new(0)
per_corpus = {}
exceptions = []

$stdout.sync = true
puts "== Genie corpus EXECUTE-sweep =="
puts "engine VERSION #{Lich::Genie::VERSION}"
puts "outer kill=#{OUTER_TIMEOUT}s  nil_cap=#{NIL_CAP}  line_budget=#{LINE_BUDGET}"
puts '=' * 78

CORPORA.each do |label, dir|
  unless Dir.exist?(dir)
    puts "  #{label}: DIR MISSING (#{dir})"
    next
  end
  files = enumerate(dir)
  files = files.select { |f| f.include?(only) } if only
  files = files.first(limit) if limit
  loader = loader_for(dir)
  counts = Hash.new(0)
  t0 = Time.now
  puts "\n-- #{label} (#{files.length} scripts) --"

  files.each_with_index do |path, idx|
    res = execute_one(path, loader)
    counts[res[:outcome]] += 1
    grand[res[:outcome]] += 1
    log.puts(JSON.generate(res.merge(corpus: label)))

    if res[:outcome] == 'EXCEPTION'
      exceptions << res.merge(corpus: label)
      puts "  !! EXCEPTION  #{File.basename(path)}: #{res[:error_class]}: #{res[:error_message]}"
      (res[:genie_frames].empty? ? res[:backtrace_top] : res[:genie_frames]).each do |fr|
        puts "        #{fr}"
      end
    elsif res[:outcome] == 'TIMEOUT'
      puts "  .. TIMEOUT    #{File.basename(path)} (outer kill fired)"
    end

    if ((idx + 1) % 100).zero? || idx + 1 == files.length
      puts "     progress #{idx + 1}/#{files.length}  " + OUTCOMES.map { |o| "#{o.downcase}=#{counts[o]}" }.join(' ')
    end
  end

  counts[:elapsed] = (Time.now - t0).round(1)
  per_corpus[label] = counts
end

log.close

# --- summary --------------------------------------------------------------

lines = []
lines << ('=' * 78)
lines << 'CORPUS EXECUTE-SWEEP SUMMARY'
lines << ('=' * 78)
cols = { 'CLEAN' => 'clean', 'ENGINE_MSG' => 'engmsg', 'GUARD_SCRIPTTIMEOUT' => 'g-tmout', 'GUARD_SENDLOOP' => 'g-send',
         'INPUT_EXHAUSTED' => 'exhaust', 'TIMEOUT' => 'timeout', 'LOAD_FAILED' => 'loadfail', 'EXCEPTION' => 'exc' }
lines << format("  %-18s %6s#{' %8s' * cols.length}", 'corpus', 'total', *cols.values)
lines << ('-' * 78)
total = 0
per_corpus.each do |label, c|
  n = OUTCOMES.sum { |o| c[o] }
  total += n
  lines << format("  %-18s %6d#{' %8d' * cols.length}", label, n, *OUTCOMES.map { |o| c[o] })
end
lines << ('-' * 78)
lines << format("  %-18s %6d#{' %8d' * cols.length}", 'TOTAL', total, *OUTCOMES.map { |o| grand[o] })
lines << ('=' * 78)
lines << '  g-tmout = scripttimeout watchdog (Genie parity, Script.cs:1819-1830 R); g-send = our send-history'
lines << '  loop guard (NOT in Remix, N01/D2: must reach 0 after WPR); engmsg = finished with a [diagnostic].'
lines << ''
lines << "EXCEPTIONS (#{exceptions.length}) -- candidate BUGS:"
if exceptions.empty?
  lines << '  (none)'
else
  exceptions.each do |e|
    lines << "  * #{e[:path]}"
    lines << "      #{e[:error_class]}: #{e[:error_message]}"
    (e[:genie_frames].empty? ? e[:backtrace_top] : e[:genie_frames]).each { |fr| lines << "        #{fr}" }
  end
end

out = lines.join("\n")
puts "\n#{out}"
File.write(SUMMARY_PATH, out + "\n")
puts "\nper-script log: #{LOG_PATH}"
puts "summary:       #{SUMMARY_PATH}"
