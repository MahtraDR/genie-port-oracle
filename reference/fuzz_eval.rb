# String-function parity fuzzer for `eval` (Genie EvalString): compares our
# Eval#eval_string vs Genie4's real Eval.cs. Extends oracle coverage from math to the
# string/logic function layer.  bundle exec ruby reference/fuzz_eval.rb [N] [seed]
require_relative 'oracle_env'
OracleEnv.load_lich!
require 'open3'

N = (ARGV[0] || 4000).to_i
srand((ARGV[1] || 12_345).to_i)

# NOTE: no "" here -- `count(s, "")` (empty needle) is an INFINITE LOOP in Genie4's own
# Eval.cs (hangs the oracle); our engine handles it, a Genie bug we don't replicate.
STRS = ['abc', 'Hello World', 'a|b|c|d', 'foo bar', '  pad  ', 'x', 'aXbXc', 'Test123']
def str = %("#{STRS.sample}")
def n = rand(-2..6).to_s
def gen
  s = str
  case rand(20)
  when 0 then "len(#{s})"
  when 1 then "length(#{s})"
  when 2 then "substr(#{s}, #{n})"
  when 3 then "substr(#{s}, #{n}, #{n})"
  when 4 then "substring(#{s}, #{n}, #{n})"
  when 5 then "replace(#{s}, #{str}, #{str})"
  when 6 then "contains(#{s}, #{str})"
  when 7 then "instr(#{s}, #{str})"
  when 8 then "instring(#{s}, #{str})"
  when 9 then "indexof(#{s}, #{str})"
  when 10 then "lastindexof(#{s}, #{str})"
  when 11 then "startswith(#{s}, #{str})"
  when 12 then "endswith(#{s}, #{str})"
  when 13 then "tolower(#{s})"
  when 14 then "toupper(#{s})"
  when 15 then "trim(#{s})"
  when 16 then "element(#{s}, #{n})"
  when 17 then "count(#{s}, #{str})"
  # `eq` is an infix operator, not a function -- exercise it as `(a = b)`, not `eq(a,b)`.
  else "(#{s} = #{str})"
  end
end

def ours(expr)
  globals = Object.new
  globals.define_singleton_method(:key?) { |_| false }
  Lich::Genie::Eval.new(globals: globals).eval_string(expr)
rescue Lich::Genie::Error
  'RUBYERR:Lich::Genie::Error' # Eval::Fault: what .NET throws inside Eval.cs (WP8)
rescue StandardError => e
  "ERR:#{e.class.name.split('::').last}"
end

cases = Array.new(N) { gen }
out, = OracleEnv.capture3(cases.map { |e| "eval\t#{e}" }.join("\n"))
g = out.split("\n")
abort "count mismatch #{g.length} vs #{cases.length}" unless g.length == cases.length

match = 0
diffs = Hash.new { |h, k| h[k] = [] }
all_diffs = []
cases.each_with_index do |e, i|
  o = ours(e).to_s
  go = g[i]
  # Both refuse (Genie's exception vs our Lich::Genie::Error) = the same outcome, like the
  # repo golden spec's ERR tolerance (G46 decision: ours stops the script).
  if o == go || (go.start_with?('ERR:') && o == 'RUBYERR:Lich::Genie::Error')
    match += 1
  else
    fn = e[/\A[a-z]+/] || '?'
    all_diffs << ['eval', e, o, go]
    diffs[fn] << [e, o, go] if diffs[fn].size < 4
  end
end

total_diff = diffs.values.sum(&:size)
puts "\n#{'=' * 74}"
puts "  eval string-function parity vs Genie #{OracleEnv::TREE}  (#{N} exprs, seed #{ARGV[1] || 12_345})"
puts '=' * 74
puts "  MATCH: #{match} / #{N}   DIFF functions: #{diffs.keys.sort.join(', ')}"
puts '=' * 74
diffs.sort_by { |k, _| k }.each do |fn, samples|
  puts "  #{fn}:"
  samples.each { |e, o, go| puts format('     %-32s ours=%-14s genie=%s', e[0, 32], o.inspect[0, 14], go.inspect) }
end
puts '=' * 74
exit OracleEnv.finish('fuzz_eval', all_diffs, total: cases.length)
