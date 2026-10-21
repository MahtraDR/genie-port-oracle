# Number-parsing parity fuzzer: our Numeric.* vs Genie4's real conversions.
#   s2d    -> Utility.StringToDouble      (Numeric.string_to_double)  -- drives Eval comparisons
#   s2i    -> Utility.StringToInteger     (Numeric.string_to_integer) -- EvalRandom's bounds
#             (Script.cs:3119 R; WP8-r1 NB5). Until WP8-r1 this mode was `toint` (VB
#             Conversions.ToInteger vs the lenient Numeric.to_integer), a pairing no Remix path
#             has: EvalRandom never used Conversions.ToInteger and the $roundtime offset is
#             Convert.ToInt32 of a DOUBLE (Game.cs:2376 R). Eval's substr uses the strict
#             VbConversions.to_integer (fuzz_vb_toint.rb). No `tolong` mode since WP8: Remix calls
#             Conversions.ToLong only on a DOUBLE (MathEval.cs:217 R, `\`), never on a string.
#   bundle exec ruby reference/fuzz_numeric.rb [N] [seed]
#
# s2d never throws (returns -1 on failure) so it's compared by VALUE (the oracle's "R"
# round-trippable string re-parses to the exact bits). s2i never throws either (-1).
require_relative 'oracle_env'
OracleEnv.load_lich!
require 'open3'

N = (ARGV[0] || 4000).to_i
srand((ARGV[1] || 12_345).to_i)

NM = Lich::Genie::Numeric
INF = [0x221E].pack('U') # en-US PositiveInfinitySymbol, which double.Parse accepts

# A grab-bag of numeric-ish tokens: valid forms, edge forms, and things Ruby's Float()
# is (wrongly) lenient about vs .NET (hex, underscores, "Infinity"), plus overflow magnitudes.
def digits(n) = Array.new(n) { rand(10) }.join
def with_commas(s)
  return s if s.length < 2

  out = s.dup
  rand(1..2).times { out.insert(rand(1..out.length - 1), ',') }
  out
end

def gen
  case rand(25)
  when 0 then digits(rand(1..6))
  when 1 then "-#{digits(rand(1..6))}"
  when 2 then "+#{digits(rand(1..4))}"
  when 3 then "#{digits(rand(1..4))}.#{digits(rand(1..4))}"
  when 4 then "-#{digits(rand(1..3))}.#{digits(rand(1..3))}"
  when 5 then ".#{digits(rand(1..4))}"
  when 6 then "#{digits(rand(1..3))}."
  when 7 then "#{digits(rand(1..3))}#{['e', 'E'].sample}#{['', '+', '-'].sample}#{digits(rand(1..3))}"
  when 8 then with_commas(digits(rand(2..7)))
  when 9 then "#{with_commas(digits(rand(2..6)))}.#{digits(rand(1..3))}"
  when 10 then "  #{digits(rand(1..4))}  "
  when 11 then digits(rand(10..25)) # overflow candidate
  when 12 then "-#{digits(rand(10..25))}"
  when 13 then "#{['x.5', '2.5', '3.5', '-2.5', '0.5', '1.5'].sample}"
  when 14 then ['0x1F', '0X10', "#{digits(2)}_#{digits(2)}", '1_000'].sample
  when 15 then ['nan', 'NaN', 'NAN', '+nan', 'Infinity', '-Infinity', 'inf', INF, "-#{INF}", "+#{INF}", " #{INF} ", "--#{INF}",
                 "1#{INF}", "#{INF}-", ".#{INF}", "#{INF}#{INF}", "#{INF}e5", "- #{INF}"].sample # INF: WP8-r1 parity B1
  when 16 then ['', ' ', '.', ',', '+', '-', '+-5', '5abc', 'abc', '1.2.3'].sample
  when 17 then with_commas(digits(rand(1..3))) + ',' # trailing comma
  when 18 then ",#{digits(rand(1..3))}" # leading comma
  when 19 then "#{digits(rand(1..3))}.#{digits(1)},#{digits(1)}" # comma after decimal
  when 20 then "#{digits(rand(1..15))}#{['e', 'E'].sample}#{rand(-400..400)}" # over/underflow exp
  when 21 then "000#{digits(rand(1..4))}" # leading zeros
  when 22 then rand(-5..5).to_s
  when 23 then wrap_white(gen) # WP8-r2: .NET number white vs char.IsWhiteSpace vs NUL
  else "#{rand(-9..9)}.#{rand(0..9)}#{rand(0..9)}"
  end
end

# Every white class on either side (no CR / LF: --stdin is line-based and .NET's ReadLine splits
# on a lone CR too). NUL: a number allows trailing NULs only; U+00A0 / U+3000 / U+0085 / U+2028:
# char.IsWhiteSpace (the NaN / infinity fallback) but not number white; U+200B / U+FEFF / U+001C:
# neither.
WHITE = ["\0", "\t", "\v", "\f", ' ', [0xA0].pack('U'), [0x3000].pack('U'), [0x85].pack('U'), [0x2028].pack('U'),
         [0x200B].pack('U'), [0xFEFF].pack('U'), [0x1C].pack('U')].freeze
def wrap_white(token)
  lead = rand(3).zero? ? '' : Array.new(rand(1..2)) { WHITE.sample }.join
  trail = rand(3).zero? ? '' : Array.new(rand(1..2)) { WHITE.sample }.join
  lead + token + trail
end

def cmp_double(ours, oracle_str)
  # s2d prints "R" InvariantCulture: NaN / Infinity / -Infinity are values (OracleEnv.parse_double).
  OracleEnv.same_double?(ours, OracleEnv.parse_double(oracle_str)) && (ours.to_f.nan? || ours == OracleEnv.parse_double(oracle_str))
end

def ours_int(_mode, s)
  NM.string_to_integer(s).to_s
rescue StandardError
  'ERR'
end

cases = Array.new(N) { gen }
lines = []
cases.each do |c|
  %w[s2d s2i].each { |m| lines << "#{m}\t#{c}" }
end
out, err, st = OracleEnv.capture3(lines.join("\n"))
abort "oracle failed (#{st}): #{err}" unless st.success?
g = out.split("\n", -1)
g.pop if g.last == ''
abort "count mismatch #{g.length} vs #{lines.length}" unless g.length == lines.length

stats = { 's2d' => [0, 0], 's2i' => [0, 0] } # [match, value_diff]
errpar = Hash.new(0) # mode -> count of err-parity (both errored) matches
diffs = Hash.new { |h, k| h[k] = [] }
all_diffs = []
lines.each_with_index do |line, i|
  tab = line.index("\t")
  mode = line[0...tab]
  s = line[(tab + 1)..]
  go = g[i]
  if mode == 's2d'
    if cmp_double(NM.string_to_double(s), go)
      stats[mode][0] += 1
    else
      stats[mode][1] += 1
      all_diffs << [mode, s, NM.string_to_double(s).inspect, go]
      diffs[mode] << [s, NM.string_to_double(s).inspect, go] if diffs[mode].size < 8
    end
  else
    ours = ours_int(mode, s)
    oracle = go.start_with?('ERR') ? 'ERR' : go
    if ours == oracle
      stats[mode][0] += 1
      errpar[mode] += 1 if oracle == 'ERR'
    else
      stats[mode][1] += 1
      all_diffs << [mode, s, ours, go]
      diffs[mode] << [s, ours, go] if diffs[mode].size < 8
    end
  end
end

puts "\n#{'=' * 74}"
puts "  Numeric parsing parity vs Genie #{OracleEnv::TREE}  (#{N} inputs x2 modes, seed #{ARGV[1] || 12_345})"
puts '=' * 74
%w[s2d s2i].each do |m|
  match, diff = stats[m]
  extra = m == 's2d' ? '' : "  (of matches, #{errpar[m]} are both-error)"
  puts format('  %-7s MATCH %5d / %5d   DIFF %d%s', m, match, match + diff, diff, extra)
end
puts '=' * 74
diffs.each do |mode, samples|
  next if samples.empty?

  puts "  #{mode} diffs:"
  samples.each { |s, o, go| puts format('     in=%-16s ours=%-16s genie=%s', s.inspect[0, 16], o.to_s[0, 16], go) }
end
puts '=' * 74
exit OracleEnv.finish('fuzz_numeric', all_diffs, total: lines.length)
