# String-parity fuzzer for evalmath: compares our format_double(MathEval.evaluate(e))
# against Genie4's actual `evalmath` string output (Command.cs EvalMath = double.ToString()
# under en-US). Catches FORMATTING divergences the numeric-tolerance fuzzer misses.
#   bundle exec ruby reference/fuzz_format.rb [N] [seed]
require_relative 'oracle_env'
OracleEnv.load_lich!
require 'open3'

N = (ARGV[0] || 4000).to_i
srand((ARGV[1] || 12_345).to_i)

BIN = %w[+ - * / % ^ \\]
FN  = %w[round sqrt abs log ln floor ceiling]
def num = rand < 0.3 ? "#{rand(0..40)}.#{rand(0..9)}" : rand(-20..99).to_s
def expr(d = 0)
  return num if d > 2 || rand < 0.35
  case rand(4)
  when 0 then "(#{expr(d + 1)} #{BIN.sample} #{expr(d + 1)})"
  when 1 then "#{FN.sample}(#{expr(d + 1)})"
  when 2 then "-#{expr(d + 1)}"
  else "#{rand(0..7)}!"
  end
end

def our_evalmath(e)
  Lich::Genie::Numeric.format_double(Lich::Genie::MathEval.evaluate(e))
rescue StandardError
  :err
end

cases = Array.new(N) { expr }
out, = OracleEnv.capture3(cases.map { |e| "evalmath\t#{e}" }.join("\n"))
g_lines = out.split("\n")
abort "count mismatch" unless g_lines.length == cases.length

cat = Hash.new(0)
samples = Hash.new { |h, k| h[k] = [] }
all_diffs = []
cases.each_with_index do |e, i|
  g = g_lines[i]
  ours = our_evalmath(e)
  g_err = g.start_with?('ERR')
  next (cat[:both_err] += 1) if ours == :err && g_err
  if ours.to_s == g
    cat[:match] += 1
  elsif ours == :err || g_err
    all_diffs << ['evalmath', e, ours, g]
    cat[:one_err] += 1; samples[:one_err] << [e, ours, g] if samples[:one_err].size < 5
  else
    # classify the string divergence
    kind = if g.include?('E') || ours.to_s.include?('e') then :sci_format
           else :other_format
           end
    all_diffs << ['evalmath', e, ours, g]
    cat[kind] += 1
    samples[kind] << [e, ours, g] if samples[kind].size < 8
  end
end

puts "\n#{'=' * 78}"
puts "  evalmath STRING parity vs Genie #{OracleEnv::TREE}  (#{N} exprs, seed #{ARGV[1] || 12_345})"
puts '=' * 78
puts "  exact string MATCH   : #{cat[:match]}"
puts "  both errored         : #{cat[:both_err]}"
puts "  sci-notation format  : #{cat[:sci_format]}   (extreme magnitudes: 1E-05 vs 1.0e-05)"
puts "  OTHER string diff    : #{cat[:other_format]}   <-- reachable-range concerns"
puts "  one-side errored     : #{cat[:one_err]}"
puts '=' * 78
%i[other_format sci_format one_err].each do |k|
  next if samples[k].empty?

  puts "  #{k}:"
  samples[k].each { |e, o, g| puts format('     %-34s ours=%-16s genie=%s', e[0, 34], o.to_s[0, 16], g) }
end
puts '=' * 78
exit OracleEnv.finish('fuzz_format', all_diffs, total: cases.length)
