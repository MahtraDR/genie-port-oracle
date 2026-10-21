# Argument-tokenizer parity fuzzer for `parseargs` (Genie Utility.ParseArgs): compares
# our Text.parse_args vs Genie4's real Utility.cs ParseArgs (extracted into the oracle's
# Shims.cs). Genie's brace/quote arg grouping drives #trigger/#class/command dispatch, so
# this is the highest-value evaluator-adjacent surface left.
#   bundle exec ruby reference/fuzz_parseargs.rb [N] [seed]
#
# Serialization (both sides): "<count>\x1f<tok0>\x1f<tok1>...". The leading count keeps a
# 0-token result ("") distinct from a single empty-string token ("{}"). A lone-quote token
# makes Genie THROW (oracle -> "ERR:Exception"); we raise + rescue to "ERR" and treat any
# oracle "ERR:*" as a match iff we also errored.
require_relative 'oracle_env'
OracleEnv.load_lich!
require 'open3'

N = (ARGV[0] || 4000).to_i
srand((ARGV[1] || 12_345).to_i)

# Assembled from structural atoms (balanced + unbalanced braces/quotes, nested, empty
# groups, escapes, underscores, single quotes, padding) -- plus pure random-char strings
# over a stress alphabet for breadth. NO "\n"/"\t"/"\x1f" (they'd break the wire format).
ATOMS = [
  'foo', 'bar', 'a', 'b', 'xy', 'word', 'cast', 'put on',
  ' ', '  ', '{', '}', '{ }', '{a}', '{a b}', '{{', '}}',
  '"', '"q"', '"q', 'q"', "'", "'s'", '\\', '\\ ', 'a_b', 'foo_bar', '_',
  'x{y}z', 'a}b', '{a{b}c}', '', 'say "hi"', '{a};{b}', 'a"b"c', '\\{b}'
].freeze
ALPHA = ['a', 'b', 'c', ' ', '{', '}', '"', "'", '\\', '_', 'x'].freeze

def gen
  if rand(2).zero?
    Array.new(rand(1..6)) { ATOMS.sample }.join(rand(2).zero? ? '' : ' ')
  else
    Array.new(rand(0..12)) { ALPHA.sample }.join
  end
end

def ours(mode, expr)
  us = (mode == 'parseargs_')
  toks = Lich::Genie::Text.parse_args(expr, treat_underscore_as_space: us)
  ([toks.length.to_s] + toks).join("\x1f")
rescue StandardError
  'ERR'
end

def category(s)
  cats = []
  cats << 'brace'  if s.include?('{') || s.include?('}')
  cats << 'dquote' if s.include?('"')
  cats << 'squote' if s.include?("'")
  cats << 'esc'    if s.include?('\\')
  cats << 'us'     if s.include?('_')
  cats << 'plain'  if cats.empty?
  cats.join('+')
end

cases = Array.new(N) { gen }
# Run every case under BOTH the plain and underscore-as-space variants.
lines = []
cases.each do |e|
  lines << "parseargs\t#{e}"
  lines << "parseargs_\t#{e}"
end
out, err, st = OracleEnv.capture3(lines.join("\n"))
abort "oracle failed (#{st}): #{err}" unless st.success?
g = out.split("\n", -1)
g.pop if g.last == '' # trailing newline artifact
abort "count mismatch #{g.length} vs #{lines.length}" unless g.length == lines.length

match = 0
diffs = Hash.new { |h, k| h[k] = [] }
all_diffs = []
lines.each_with_index do |line, i|
  tab = line.index("\t")
  mode = line[0...tab]
  expr = line[(tab + 1)..]
  o = ours(mode, expr)
  go = g[i]
  go = 'ERR' if go.start_with?('ERR')
  if o == go
    match += 1
  else
    all_diffs << [mode, expr, o, go]
    cat = category(expr)
    cat += '/us' if mode == 'parseargs_'
    diffs[cat] << [expr, o, go] if diffs[cat].size < 6
  end
end

total = lines.length
puts "\n#{'=' * 74}"
puts "  ParseArgs parity vs Genie #{OracleEnv::TREE}  (#{N} exprs x2 modes = #{total}, seed #{ARGV[1] || 12_345})"
puts '=' * 74
puts "  MATCH: #{match} / #{total}   DIFF categories: #{diffs.keys.sort.join(', ')}"
puts '=' * 74
diffs.sort_by { |k, _| k }.each do |cat, samples|
  puts "  #{cat}:"
  samples.each do |e, o, go|
    puts format('     in=%-22s ours=%-22s genie=%s', e.inspect[0, 22], o.inspect[0, 22], go.inspect)
  end
end
puts '=' * 74
exit OracleEnv.finish('fuzz_parseargs', all_diffs, total: lines.length)
