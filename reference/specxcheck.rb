# frozen_string_literal: true

# Cross-check the LITERAL expectations hand-written in our eval/math specs against the real
# Genie evaluators (promoted in WP0 from audits/2026-10-18/evidence/tests-tooling/specxcheck.rb).
# A spec that asserts a value Genie does not produce is a spec bug (it locks in a divergence).
#   [GENIE=remix] ruby reference/specxcheck.rb      # exit 1 if any spec literal disagrees with Genie
require_relative 'oracle_env'

S = File.join(OracleEnv::LICH, 'spec/lib/genie/')
unq = ->(t) { t.gsub("\\'", "'").gsub('\\\\', '\\') }
cases = []
File.read(S + 'eval_spec.rb').scan(/truthy\('((?:[^'\\]|\\.)*)'\)\)\.to be\((true|false)\)/) { |e, v| cases << ['evalbool', unq.call(e), v == 'true' ? '1' : '0'] }
File.read(S + 'eval_spec.rb').scan(/str\('((?:[^'\\]|\\.)*)'\)\)\.to eq\('((?:[^'\\]|\\.)*)'\)/) { |e, v| cases << ['eval', unq.call(e), unq.call(v)] }
File.read(S + 'math_eval_spec.rb').scan(/evl\('((?:[^'\\]|\\.)*)'\)\)\.to eq\(([-0-9.e]+)\)/) { |e, v| cases << ['math', e.gsub('\\\\', '\\'), v] }
cases.reject! { |_m, e, _| e =~ /def\(|knownvar|\$|%/ }
g = OracleEnv.run(cases.map { |m, e, _| "#{m}\t#{e}" })
diffs = []
cases.each_with_index do |(m, e, want), i|
  got = g[i].to_s
  ok = m == 'math' ? OracleEnv.same_double?(Float(want), OracleEnv.parse_double(got)) : got == want
  diffs << [m, e, want, got] unless ok
end
puts "specxcheck vs #{OracleEnv::TREE}: checked #{cases.size} spec literal expectations; #{diffs.size} disagree"
diffs.each { |m, e, want, got| puts "  SPEC!=GENIE #{m} #{e.inspect} spec=#{want.inspect} genie=#{got.inspect}" }
exit(diffs.empty? ? 0 : 1)
