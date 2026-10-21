# Differential simulation: our in-Lich Genie engine vs native-Genie behavior.
# The "native (Genie4)" column is derived from the Genie4 C# source (algorithms in
# Utility/MathEval/Eval/Command.cs/Script.cs), NOT a live run, except scenario 6 (pinned from
# the real Remix engine, flow-oracle genieflow). Scenarios are chosen where a NAIVE port would
# diverge from Genie. A smoke check only: the real-engine oracles (reference/fuzz_*.rb against
# genieoracle, flow-oracle/diff_driver.rb against genieflow) are the parity gates.
#   BUNDLE_GEMFILE=<lich-5>/Gemfile bundle exec ruby reference/sim_compare.rb   (exit 1 on a DIFF)
require_relative 'lab_paths'
$LOAD_PATH.unshift(LabPaths.lich_lib)
require 'genie'
include Lich::Genie

ROWS = []
def check(scenario, input, ours, native, note = '')
  ok = ours.to_s == native.to_s
  ROWS << [ok, scenario, input, ours.to_s, native.to_s, note]
  ok
end

# --- helpers ---------------------------------------------------------------
def mathe(expr) = Lich::Genie::Numeric.format_double(MathEval.evaluate(expr))
def eval_bool(expr)
  globals = Object.new; globals.define_singleton_method(:key?) { |_| false }
  Eval.new(globals: globals).do_eval(expr) ? '1' : '0'
end
def run_script(src, input: [], game_state: nil)
  cmds = []; echoes = []
  clock = [0.0]
  input_obj = Object.new.tap do |o|
    lines = input.dup
    o.define_singleton_method(:next_line) { |timeout: nil| lines.empty? ? (clock[0] += (timeout || 1); nil) : lines.shift }
  end
  game = Object.new.tap { |o| o.define_singleton_method(:send_command) { |t| cmds << t } }
  vars = Variables.new(game_state: game_state)
  Engine.run(src, variables: vars, game: game, input: input_obj, echo: ->(t) { echoes << t }, clock: -> { clock[0] })
  { cmds: cmds, echoes: echoes, vars: vars }
end

# === 1. Math quirks (native col = Genie4 Utility/MathEval algorithm) =========
check('exponent is LEFT-associative',      '2 ^ 3 ^ 2', mathe('2 ^ 3 ^ 2'), '64',   'naive right-assoc = 512')
check("banker's rounding round(2.5)",      'round(2.5)', mathe('round(2.5)'), '2',   'naive half-up = 3')
check("banker's rounding round(3.5)",      'round(3.5)', mathe('round(3.5)'), '4',   'half-up also 4 here')
check('log is base-10',                    'log(100)',   mathe('log(100)'),  '2',    'naive natural log ~4.605')
check('ln is natural',                     'ln(1)',      mathe('ln(1)'),     '0',    '')
check('modulo takes dividend sign',        '-7 % 3',     mathe('-7 % 3'),    '-1',   'Ruby floored mod = 2')
check('integer division truncates to 0',   '-7 \\ 2',    mathe('-7 \\ 2'),   '-3',   'trunc toward zero')
check('factorial postfix',                 '5!',         mathe('5!'),        '120',  '')

# === 2. Eval: string vs numeric comparison (Genie Eval.cs) ==================
check('quoted operands compare as STRINGS','("10" > "9")', eval_bool('("10" > "9")'), '0', 'string "10" < "9"')
check('bare numbers compare NUMERICALLY',  '(10 > 9)',      eval_bool('(10 > 9)'),      '1', '')
check('relational on strings is false',    '("abc" > "abd")', eval_bool('("abc" > "abd")'), '0', 'Genie: rel ops on strings => false')
check('only strictly-positive is truthy',  '(5 && 0)',      eval_bool('(5 && 0)'),      '0', '0 is false in and/or')

# === 3. #if runs EVERY ;-command in the taken branch (R4 fix) ================
r = run_script("put #if {(1 = 1)} {#var a 1;#var b 2;#var c 3}\nexit\n")
check('#if branch runs all ; commands', '{#var a 1;#var b 2;#var c 3}',
      [r[:vars].global_get('a'), r[:vars].global_get('b'), r[:vars].global_get('c')].join(','), '1,2,3',
      'pre-R4 only first ran')

# === 4. Variable substitution + \$ escaping =================================
r = run_script("setvariable name Bob\necho hello %name and \\$literal\nexit\n")
check('local subst + \\$ escape', 'echo hello %name and \\$literal', r[:echoes].first, 'hello Bob and $literal', '')

# === 5. Action class gating (v0.9.3) =======================================
src = "action (m) var hit yes when ^ding\naction (m) off\nmatch ok never\nmatchwait 1\necho %hit\nexit\n"
check('action fires only when class on', 'define (m); off; ding', run_script(src, input: ['ding'])[:echoes].first, '%hit', 'class off => no fire (literal)')
src2 = "action (m) var hit yes when ^ding\nmatch ok never\nmatchwait 1\necho %hit\nexit\n"
check('action fires when class on (default)', 'define (m); ding', run_script(src2, input: ['ding'])[:echoes].first, 'yes', '')

# === 6. jscall with no JS loaded (WP12/D4: Jint 4 like Remix) ================
# Native column from the REAL Remix engine (flow-oracle genieflow, 2026-10-20): with no js
# include, Remix prints "[Script error in <file>(3): doXCompare is not defined]" and %v is
# "undefined". (The old expectation "8" was upstream Genie4's Jint 2 + a loaded js_arrays.js.)
src3 = "setvariable sizes tiny|small|medium|large\nsetvariable volumes 1|2|4|8\njscall v doXCompare(\"sizes\",\"volumes\",\"large\")\necho %v\nexit\n"
e3 = run_script(src3)[:echoes]
check('jscall, no JS loaded: error + undefined', 'doXCompare(sizes,volumes,large)',
      [e3.first.to_s.sub(/\(\d+\)/, '(N)').sub(/ in \S+\.cmd/, ' in X.cmd'), e3.last].join(' / '),
      '[Script error in X.cmd(N): doXCompare is not defined] / undefined', 'Remix genieflow')

# === 7. matchwait: first matching label wins, captures exported =============
src4 = "match dead has died\nmatch flee You are low\nmatchwait 5\ndead:\nput loot\nexit\nflee:\nput run\nexit\n"
check('matchwait picks the matched branch', 'stream: "the orc has died"', run_script(src4, input: ['the orc has died'])[:cmds].first, 'loot', '')

# === 8. counter / math verbs (Genie MathCalc) ==============================
r = run_script("setvariable n 5\nmath n multiply 3\nmath n subtract 1\necho %n\nexit\n")
check('math verb chain', 'n=5; *3; -1', r[:echoes].first, '14', '')

# --- report ----------------------------------------------------------------
puts
puts '='*100
puts format('  %-42s | %-9s | %-9s | %s', 'SCENARIO', 'OURS', 'GENIE4', 'VERDICT')
puts '='*100
pass = 0
ROWS.each do |ok, scn, _inp, ours, native, note|
  pass += 1 if ok
  mark = ok ? 'MATCH' : '*** DIFF ***'
  puts format('  %-42s | %-9s | %-9s | %s', scn[0, 42], ours[0, 9], native[0, 9], mark)
  puts format('  %-42s |   %s', '', note) unless note.empty?
end
puts '='*100
puts "  #{pass}/#{ROWS.length} scenarios match native-Genie expected behavior"
puts '='*100
exit(pass == ROWS.length ? 0 : 1)
