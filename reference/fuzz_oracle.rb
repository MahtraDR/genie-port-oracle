# Differential fuzzer: random expressions through BOTH the real Genie4 evaluators
# (genieoracle, C#) and our Ruby engine (MathEval/Eval), reporting any divergence.
# This is a TRUE oracle (Genie4's actual Eval.cs/MathEval.cs), not a source model.
#
# Usage: bundle exec ruby reference/fuzz_oracle.rb [N]
require_relative 'oracle_env'
OracleEnv.load_lich!

N = (ARGV[0] || 2000).to_i
srand((ARGV[1] || 12_345).to_i) # reproducible

# --- expression generators --------------------------------------------------
INTS = (0..99)
def num = rand < 0.3 ? "#{rand(0..40)}.#{rand(0..9)}" : rand(-20..99).to_s
MATH_BIN = %w[+ - * / % ^ \\]
MATH_FN  = %w[round sqrt abs log ln floor ceiling sin cos tan]

def math_expr(depth = 0)
  return num if depth > 2 || rand < 0.35
  case rand(4)
  when 0 then "(#{math_expr(depth + 1)} #{MATH_BIN.sample} #{math_expr(depth + 1)})"
  when 1 then "#{MATH_FN.sample}(#{math_expr(depth + 1)})"
  when 2 then "-#{math_expr(depth + 1)}"
  else        "#{rand(0..7)}!"
  end
end

CMP = %w[> < = != >= <=]
def operand = rand < 0.5 ? num : %("#{%w[abc abd 10 9 x foo].sample}")
def bool_expr(depth = 0)
  return "(#{operand} #{CMP.sample} #{operand})" if depth > 1 || rand < 0.5
  case rand(3)
  when 0 then "(#{bool_expr(depth + 1)} && #{bool_expr(depth + 1)})"
  when 1 then "(#{bool_expr(depth + 1)} || #{bool_expr(depth + 1)})"
  else        "(!#{bool_expr(depth + 1)})"
  end
end

# Flat (unparenthesized) chains with MIXED-CASE word keywords and function-&&-comparison
# shapes: the two Remix Eval.cs deltas (keyword regex IgnoreCase, Eval.cs:92 R; && / ||
# reset iArgLeft, Eval.cs:532-546 R) that the parenthesized generator above never reaches.
KW = %w[and AND And or OR Or]
FNS = ['contains("abc", "b")', 'contains("abc", "z")', 'startswith("abc", "a")', 'len("ab")', 'instr("abc", "c")']
def flat_atom = rand < 0.4 ? FNS.sample : "#{num} #{CMP.sample} #{num}"
def flat_bool
  e = rand < 0.2 ? "#{%w[not NOT Not !].sample} #{flat_atom}" : flat_atom
  rand(1..3).times { e += " #{rand < 0.5 ? KW.sample : %w[&& ||].sample} #{flat_atom}" }
  e
end

# --- our-engine evaluators (normalize to strings comparable with the oracle) --
def our_math(expr)
  v = Lich::Genie::MathEval.evaluate(expr)
  v.is_a?(Float) ? v : v.to_f
rescue StandardError
  :err
end

def our_bool(expr)
  globals = Object.new; globals.define_singleton_method(:key?) { |_| false }
  Lich::Genie::Eval.new(globals: globals).do_eval(expr) ? '1' : '0'
rescue StandardError
  :err
end

# --- build the batch, run the oracle once (stdin), compare -------------------
cases = []
(N).times { cases << ['math', math_expr] }
(N).times { cases << ['evalbool', bool_expr] }
(N).times { cases << ['evalbool', flat_bool] }

require 'open3'
input = cases.map { |m, e| "#{m}\t#{e}" }.join("\n")
out, _err, status = OracleEnv.capture3(input)
abort "oracle failed: #{status}" unless status.success?
oracle_lines = out.split("\n")
abort "count mismatch #{oracle_lines.length} != #{cases.length}" unless oracle_lines.length == cases.length

stats = Hash.new(0)
value_diffs = [] # both produced a value, values differ  <-- real bugs
err_diffs = []   # one side errored, other produced a value (NaN/Inf are VALUES, see OracleEnv.parse_double)
cases.each_with_index do |(mode, expr), i|
  g = oracle_lines[i]
  if mode == 'math'
    ours = our_math(expr)
    gf = OracleEnv.parse_double(g)
    if ours == :err && gf.nil? then stats[:both_err] += 1
    elsif ours == :err || gf.nil? then stats[:one_err] += 1; err_diffs << [mode, expr, ours, g]
    elsif OracleEnv.same_double?(ours, gf) then stats[:match] += 1
    else stats[:diff] += 1; value_diffs << [mode, expr, ours, g]
    end
  else
    ours = our_bool(expr)
    g_err = g.start_with?('ERR')
    if ours == :err && g_err then stats[:both_err] += 1
    elsif ours == :err || g_err then stats[:one_err] += 1; err_diffs << [mode, expr, ours, g]
    elsif ours.to_s == g then stats[:match] += 1
    else stats[:diff] += 1; value_diffs << [mode, expr, ours, g]
    end
  end
end

puts "\n#{'=' * 74}"
puts "  DIFFERENTIAL FUZZ vs real Genie evaluators (#{OracleEnv::TREE})  (#{cases.length} cases: #{N} math + #{N} bool + #{N} flat bool)"
puts '=' * 74
puts "  MATCH            : #{stats[:match]}"
puts "  both errored     : #{stats[:both_err]}   (agree it's invalid)"
puts "  VALUE DIFFERENCE : #{stats[:diff]}"
puts "  one-side errored : #{stats[:one_err]}"
puts '=' * 74
exit OracleEnv.finish('fuzz_oracle', value_diffs + err_diffs, total: cases.length)
