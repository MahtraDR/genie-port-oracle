# Unicode parity fuzzer for matchre / replacere: .NET's \d \w \s are Unicode-aware and
# its ^ $ anchor the whole string; Ruby's \d \w \s are ASCII and ^ $ are line-anchored.
# fuzz_regex.rb kept subjects ASCII + newline-free, so this round targets the gap.
#
# Multiline (^ $) is NOT fuzzed: a Genie "..." literal can't contain a raw newline and
# game lines arrive one-per-line, so a multi-line SUBJECT can't occur in practice.
# This isolates the Unicode \d\w\s divergence, which non-ASCII subjects CAN hit.
#
# Set EVAL_PATH to load a patched eval.rb copy (fix-verification).
#   bundle exec ruby reference/fuzz_regex_unicode.rb [N] [seed]
require_relative 'oracle_env'
OracleEnv.load_lich!
require 'open3'

load ENV['EVAL_PATH'] if ENV['EVAL_PATH']

N = (ARGV[0] || 3000).to_i
srand((ARGV[1] || 12_345).to_i)

# Non-ASCII (and mixed) subjects: accented Latin, Greek, Cyrillic, Arabic-Indic digits,
# separators, currency/marks. NO double-quote / newline / tab.
SUBJECTS = [
  'cafe', 'cafe\u',            # placeholders replaced below
  'x', '42', 'abc def'
].freeze

# Build subjects with real codepoints so the source file stays portable.
UNI = [
  'caf' + [0x00E9].pack('U'),                       # cafe(e-acute)
  'na' + [0x00EF].pack('U') + 've',                 # naive(i-diaeresis)
  'Zo' + [0x00EB].pack('U'),                        # Zoe(e-diaeresis)
  [0x03B1, 0x03B2, 0x03B3].pack('U*'),              # Greek alpha beta gamma
  [0x0430, 0x0431, 0x0432].pack('U*'),              # Cyrillic a b v
  [0x0661, 0x0662, 0x0663].pack('U*'),              # Arabic-Indic 1 2 3
  [0x00F1].pack('U') + 'o',                         # n-tilde + o
  'a' + [0x00A0].pack('U') + 'b',                   # a + NBSP + b
  '5' + [0x20AC].pack('U'),                         # 5 + euro sign
  'the ' + [0x00E9].pack('U') + 'lite team',        # sentence w/ accent
  [0x00E9].pack('U') + '1' + [0x0663].pack('U'),    # accent + ascii digit + arabic digit
  'abc', 'Hello World', 'HP: 42/100', '  pad  '
].freeze

# Patterns centered on the Unicode-sensitive shorthands, inside + outside char classes,
# positive + negated, anchored + not.
PATTERNS = [
  '\\w+', '^\\w+$', '\\d+', '^\\d+$', '\\s', '\\s+', '\\S+', '\\D+', '\\W+',
  '\\w', '\\d', '(\\w+)', '(\\w+)\\s(\\w+)', '\\w+\\s\\w+',
  '[\\w]+', '[\\d]+', '[\\s]', '[\\w ]+', '[a-z\\d]+', '[^\\d]+', '[^\\w]',
  '.', '.+', '[[:alpha:]]+'
].freeze

def q(s) = "\"#{s}\""
def gen
  s = UNI.sample
  p = PATTERNS.sample
  rand(2).zero? ? ['matchre', "matchre(#{q(s)}, #{q(p)})"] : ['replacere', "replacere(#{q(s)}, #{q(p)}, \"X\")"]
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
lines = []
meta = []
cases.each do |fn, expr|
  lines << "eval\t#{expr}"
  meta << [fn, 'eval', expr]
  next unless fn == 'matchre'

  lines << "matchrecaps\t#{expr}"
  meta << ['matchre_caps', 'matchrecaps', expr]
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
  both_err = o.start_with?('ERR') && go.start_with?('ERR')
  if o == go || both_err
    match[fn] += 1
  else
    all_diffs << [mode, expr, o, go]
    diffs[fn] << [expr, o, go] if diffs[fn].size < 16
  end
end

puts "\n#{'=' * 78}"
puts "  Unicode regex parity vs Genie #{OracleEnv::TREE}  (#{N} base cases, seed #{ARGV[1] || 12_345})"
puts '=' * 78
total.keys.sort.each { |fn| puts format('  %-14s MATCH %d / %d', fn, match[fn], total[fn]) }
puts '=' * 78
diffs.sort_by { |k, _| k }.each do |fn, samples|
  puts "  #{fn}  (#{samples.size} sampled):"
  samples.each { |e, o, go| puts format('     %-38s ours=%-14s genie=%s', e[0, 38], o.inspect[0, 14], go.inspect[0, 28]) }
end
puts '=' * 78
exit OracleEnv.finish('fuzz_regex_unicode', all_diffs, total: meta.length)
