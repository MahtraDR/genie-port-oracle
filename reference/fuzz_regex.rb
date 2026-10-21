# Regex string-function parity fuzzer for `eval`: compares our Eval against Genie4's
# real Eval.cs for match / matchre / replacere / replace (deliberately excluded from
# fuzz_eval.rb). Also checks matchre CAPTURE GROUPS via the oracle's `matchrecaps` mode
# (serializes Eval.ResultList like parseargs does), since matchre's return value is only
# "1"/"0" and hides the captures.
#   bundle exec ruby reference/fuzz_regex.rb [N] [seed]
#
# All exprs are ASCII, contain no " (would close a Genie string), and no newline/tab/\x1f
# (wire-format bytes). Patterns are kept SIMPLE (no nested unbounded quantifiers) to avoid
# catastrophic backtracking that would hang the --stdin oracle batch.
#
# Set EVAL_PATH env to load a patched eval.rb copy (used to verify a proposed fix); by
# default it loads the repo's lib/genie.
require_relative 'oracle_env'
OracleEnv.load_lich!
require 'open3'

if ENV['EVAL_PATH']
  load ENV['EVAL_PATH'] # override Lich::Genie::Eval with a patched copy for fix-verification
  puts "[loaded patched eval from #{ENV['EVAL_PATH']}]"
end

N = (ARGV[0] || 4000).to_i
srand((ARGV[1] || 12_345).to_i)

# Subjects: plain words, padded (leading/trailing space -> exercises matchre's subject
# handling), mixed case, digits, delimited. NO double-quote / newline / tab.
SUBJECTS = [
  'abc', 'Hello World', 'HP: 42/100', 'a|b|c', 'foo bar', '  pad  ', ' lead', 'trail ',
  'x', 'aXbXc', 'Test123', '42', 'The Cat', 'aaa', 'a1b2c3', 'end.', '.start', 'CAT',
  'one two three', '  ', '', 'a.b.c', 'go2 room', 'HP:0/0'
].freeze

# Simple regex-pattern atoms (literals, classes, anchors, quantifiers, groups, alternation,
# inline (?i), escapes, backrefs). Each is a plain Ruby string == the exact chars fed to
# both engines (Genie does NOT process backslash escapes inside "" strings, so '\\d' below
# reaches the regex engine as backslash-d on both sides).
PATTERNS = [
  'abc', 'a', 'X', 'cat', 'CAT', '.', '.*', '.+', 'a*', 'a+', 'a?', 'ab*c',
  '[a-z]', '[a-z]+', '[A-Z]', '[0-9]', '[0-9]+', '[^0-9]', '[abc]', '[abc]+',
  '^a', 'c$', '^abc$', '^', '$', '^ ', ' $', '^\\s+', '\\s+$', '\\S+',
  '\\d', '\\d+', '\\w', '\\w+', '\\s', '\\.', '\\|', '\\d+/\\d+',
  '(a)', '(ab)', '(a)(b)', '(\\d+)', '(\\d+)/(\\d+)', '(cat|dog)', 'a|b', 'cat|dog',
  '(?i)abc', '(?i)cat', '(?i)HELLO', '(?i)^a', '(a)\\1', '(.)\\1',
  '', 'zzz', 'q+', '[', '(', '*', '\\'
].freeze

# Replacement atoms for replacere / replace: plain text plus every .NET substitution token
# (valid + invalid + out-of-range group numbers). No double-quotes.
REPLACEMENTS = [
  'X', '-', '', '_', '<>', 'YY',
  '$1', '$2', '$0', '$5', '$12', '${1}', '${2}', '${9}',
  '$&', '$$', '$`', "$'", '$+', '$_', '$z', 'a$1b', '[$1]', '$1$2'
].freeze

def subj = SUBJECTS.sample
def pat = PATTERNS.sample
def repl = REPLACEMENTS.sample
def q(s) = "\"#{s}\""

# Build a (function, expr) case. matchre is emitted twice by the driver (eval + caps).
def gen
  case rand(4)
  when 0 then ['match',     "match(#{q(subj)}, #{q(subj)})"]
  when 1 then ['matchre',   "matchre(#{q(subj)}, #{q(pat)})"]
  when 2 then ['replacere', "replacere(#{q(subj)}, #{q(pat)}, #{q(repl)})"]
  else        ['replace',   "replace(#{q(subj)}, #{q(subj)}, #{q(repl)})"]
  end
end

def ours(mode, expr)
  g = Object.new
  g.define_singleton_method(:key?) { |_| false }
  ev = Lich::Genie::Eval.new(globals: g)
  if mode == 'matchrecaps'
    ev.eval_string(expr)
    caps = ev.result_list
    ([caps.length.to_s] + caps).join("\x1f")
  else
    ev.eval_string(expr)
  end
rescue StandardError => e
  "ERR:#{e.class.name.split('::').last}"
end

cases = Array.new(N) { gen }

# Wire lines: eval for all; plus a matchrecaps line for each matchre case.
lines = []
meta  = [] # [fn, mode, expr] parallel to lines
cases.each do |fn, expr|
  lines << "eval\t#{expr}"
  meta  << [fn, 'eval', expr]
  next unless fn == 'matchre'

  lines << "matchrecaps\t#{expr}"
  meta  << ['matchre_caps', 'matchrecaps', expr]
end

out, err, st = OracleEnv.capture3(lines.join("\n"))
abort "oracle failed (#{st}): #{err}" unless st.success?
g = out.split("\n", -1)
g.pop if g.last == ''
abort "count mismatch #{g.length} vs #{lines.length}" unless g.length == lines.length

match = Hash.new(0)
total = Hash.new(0)
diffs = Hash.new { |h, k| h[k] = [] }
all_diffs = []
meta.each_with_index do |(fn, mode, expr), i|
  o = ours(mode, expr).to_s
  go = g[i]
  total[fn] += 1
  # An invalid regex throws in BOTH engines; count "both errored" as a match.
  both_err = o.start_with?('ERR') && go.start_with?('ERR')
  if o == go || both_err
    match[fn] += 1
  else
    all_diffs << [mode, expr, o, go]
    diffs[fn] << [expr, o, go] if diffs[fn].size < 12
  end
end

puts "\n#{'=' * 78}"
puts "  regex-function parity vs Genie #{OracleEnv::TREE}  (#{N} base cases, seed #{ARGV[1] || 12_345})"
puts '=' * 78
total.keys.sort.each do |fn|
  puts format('  %-14s MATCH %d / %d', fn, match[fn], total[fn])
end
puts '=' * 78
diffs.sort_by { |k, _| k }.each do |fn, samples|
  puts "  #{fn}  (#{samples.size} sampled):"
  samples.each do |e, o, go|
    puts format('     %-40s ours=%-16s genie=%s', e[0, 40], o.inspect[0, 16], go.inspect[0, 30])
  end
end
puts '=' * 78
exit OracleEnv.finish('fuzz_regex', all_diffs, total: meta.length)
