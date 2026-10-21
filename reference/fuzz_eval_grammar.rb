# Grammar fuzzer for Eval (bool+string) vs real Eval.cs: flat/unparenthesized operator chains,
# barewords, unquoted args, wrong arity, nesting, unbalanced parens, negation, keywords.
#   [GENIE=remix|upstream] bundle exec ruby reference/fuzz_eval_grammar.rb [N] [seed] [--accept]
# Promoted from audits/2026-10-18/evidence/eval-math-text (WP0). Gate: the exact-key file
# reference/goldens/fuzz_eval_grammar.n<N>.s<seed>.accepted.<tree>.tsv when it exists for this
# N/seed (recorded for the default 3000/1; any NEW or CHANGED diff exits 1), else the allowlist,
# whose G06 umbrella then hides regressions (a WARNING line says so).
require_relative 'oracle_env'
OracleEnv.load_lich!
ACCEPT = !ARGV.delete('--accept').nil?
N = (ARGV[0] || 3000).to_i; SEED = (ARGV[1] || 1).to_i; srand(SEED)
FN2 = %w[contains instr indexof lastindexof match startswith endswith count matchre]
FN1 = %w[len tolower toupper trim length]
FN3 = %w[replace replacere]
ATOMS = ['0', '1', '2', '5', '-1', '2.5', '"abc"', '"1"', '""', 'abc', 'dead man', '3x', '.sc', '%x', 'true', 'false']
CMP = %w[= == != <> > < >= <=]; LOG = ['&&', '||', 'and', 'or']
def s = %("#{%w[abc b xyz 12 a|b|c].sample}")
def atom(d)
  r = rand
  return ATOMS.sample if d > 2 || r < 0.45
  if r < 0.6 then f = FN2.sample; n = [2, 2, 2, 1, 3].sample; "#{f}(#{Array.new(n) { s }.join(', ')}#{rand < 0.05 ? '' : ')'}"
  elsif r < 0.7 then "#{FN1.sample}(#{rand < 0.5 ? s : expr(d + 1)})"
  elsif r < 0.75 then "#{FN3.sample}(#{s}, #{s}, #{s})"
  elsif r < 0.85 then "(#{expr(d + 1)})"
  elsif r < 0.92 then "!#{atom(d + 1)}"
  else "not #{atom(d + 1)}" end
end
def expr(d = 0)
  e = atom(d)
  rand(0..3).times { e += " #{rand < 0.6 ? CMP.sample : LOG.sample} #{atom(d)}" }
  e
end
cases = Array.new(N) { expr }.uniq.reject { |e| e =~ /count\([^)]*""/ }  # count(x,"") hangs Genie
g = OracleEnv.run(cases.flat_map { |e| ["eval\t#{e}", "evalbool\t#{e}"] })
def o_s(e) = (Lich::Genie::Eval.new(globals: {}).eval_string(e) rescue "RUBYERR:#{$!.class}")
def o_b(e) = (Lich::Genie::Eval.new(globals: {}).do_eval(e) ? '1' : '0' rescue "RUBYERR:#{$!.class}")
bs = bb = 0
all_diffs = []
cases.each_with_index do |e, i|
  os = o_s(e); ob = o_b(e)
  if os != g[2 * i] then bs += 1; all_diffs << ['eval', e, os, g[2 * i]] end
  if ob != g[2 * i + 1] then bb += 1; all_diffs << ['evalbool', e, ob, g[2 * i + 1]] end
end
puts "fuzz_eval_grammar vs #{OracleEnv::TREE}: cases=#{cases.size}  str-diff=#{bs}  bool-diff=#{bb}"
exit OracleEnv.finish('fuzz_eval_grammar', all_diffs, total: cases.size * 2,
                     accepted: OracleEnv.accepted_path("fuzz_eval_grammar.n#{N}.s#{SEED}"), accept: ACCEPT)
