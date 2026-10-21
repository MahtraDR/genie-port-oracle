# Strict VB Conversions.ToInteger parity fuzzer: Lich::Genie::VbConversions.to_integer
# (value, or the raised .NET message) vs genieoracle `tointmsg` (value, or
# "ERR:<Type>:<Message>"). Compared on the value or the exact message text.
#   BUNDLE_GEMFILE=<lich-5>/Gemfile bundle exec ruby reference/fuzz_vb_toint.rb [N] [seed]
# Used by ScriptArgs.shift (EvalShift, Script.cs:3005 R). No allowlist: every diff fails.
require_relative 'oracle_env'
OracleEnv.load_lich!

N = (ARGV[0] || 6000).to_i
SEED = (ARGV[1] || 4242).to_i
srand(SEED)

VB = Lich::Genie::VbConversions
IDEO = [0x3000].pack('U')
INF = [0x221E].pack('U')

def digits(n) = Array.new(n) { rand(10) }.join
def hexd(n) = Array.new(n) { '0123456789abcdefABCDEFgx'[rand(24)] }.join

def core
  case rand(14)
  when 0 then digits(rand(1..6))
  when 1 then "#{digits(rand(0..4))}.#{digits(rand(0..4))}"
  when 2 then "#{digits(rand(1..3))}#{%w[e E].sample}#{['', '+', '-'].sample}#{digits(rand(0..3))}"
  when 3 then Array.new(rand(1..4)) { digits(rand(0..3)) }.join(',')
  when 4 then "#{Array.new(rand(1..3)) { digits(rand(1..3)) }.join(',')}.#{digits(rand(0..2))}"
  when 5 then digits(rand(9..12))
  when 6 then ['2.5', '3.5', '0.5', '1.5', '2147483647.5', '2147483646.5', '2147483648', '-2147483648.5'].sample
  when 7 then ['nan', 'NaN', INF, 'Infinity', 'inf', '0x1F', '1_000', 'abc', ''].sample
  when 8 then "&#{%w[H h O o B x].sample}#{['', '+', '-', '0x', ' '].sample}#{hexd(rand(0..17))}"
  when 9 then "&#{%w[H O].sample}#{%w[F 7 1].sample * rand(15..23)}"
  when 10 then "#{digits(rand(1..15))}e#{rand(-30..30)}"
  when 11 then "0#{%w[x X].sample}#{hexd(rand(1..3))}"
  else rand(-9..9).to_s
  end
end

def decorate(s)
  pre = ['', ' ', '  ', "\t", IDEO, '+', '-', '$', '(', '$-', '-$', '+$', '$ ', '- ', '( ', '$(', '+(', '(+'].sample
  post = ['', ' ', "\t", '+', '-', ')', '$', ' )', ') ', '$)', ' -', 'x', '.', ','].sample
  # Number.TrailingZeros (WPZ-r1 B1): a NUL run after the number passes, anything after it fails.
  post += ["\0", "\0\0", " \0", "\0 ", "\0x", ")\0", "-\0"].sample if rand(4).zero?
  rand(3).zero? ? s : "#{pre}#{s}#{post}"
end

def ours(s)
  VB.to_integer(s).to_s
rescue Lich::Genie::Error => e
  "ERR:#{e.message}"
end

def genie_norm(g)
  m = g.match(/\AERR:[A-Za-z]+:(.*)\z/m)
  m ? "ERR:#{m[1]}" : g
end

# Fixed NUL rows (genieoracle tointmsg, WPZ-r1 B1): trailing NULs after the whole number grammar
# pass on the double.Parse path; a leading/inner NUL, NUL then white, the &H/&O and NaN/infinity
# paths fail.
NUL_ROWS = ["5\0", "5\0\0", "5 \0", " 5 \0\0", "(5)\0", "(5\0)", "5-\0", "5$\0", "2.5\0", "5.\0",
            "1e3\0", "5e\0", "1,000\0", "99999999999\0", "5\0 ", "5\0\t", "5\0x", "5\0\0" + "5", "\05", "\0",
            " \0", "$\0", "&H1F\0", "&HFF \0", "&O7\0", "&H\0", "nan\0", "NaN \0", "#{INF}\0"].freeze
cases = (NUL_ROWS + Array.new(N) { decorate(core) }).reject { |c| c.include?("\n") }
g = OracleEnv.run(cases.map { |c| "tointmsg\t#{c}" })
diffs = []
cases.each_with_index do |c, i|
  o = ours(c)
  gn = genie_norm(g[i])
  diffs << ['tointmsg', c, o, g[i]] unless o == gn
end
errs = g.count { |x| x.start_with?('ERR:') }
puts "fuzz_vb_toint vs #{OracleEnv::TREE}: cases=#{cases.length} (genie errors #{errs}) seed=#{SEED} DIFF=#{diffs.length}"
diffs.first(30).each { |_m, c, o, gg| puts format('  in=%-28s ours=%-40s genie=%s', c.inspect, o[0, 40], gg) }
exit(diffs.empty? ? 0 : 1)
