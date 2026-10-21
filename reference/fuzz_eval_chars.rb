# Character-level fuzzer for the WP8 literal ports (Eval.cs / MathEval.cs, Remix v4.2.4):
# random strings over the characters both lexers switch on (quotes, parentheses, every
# separator, digits, '.', '-', spaces/tabs, letters, `#`, `_`, `%`, `$`) plus whole function
# names and keywords, so Parse/SectionEnqueue/ParseQueue (Eval.cs:153-397 R) and calc_scan's
# state table (MathEval.cs:418-547 R) meet inputs no grammar would write.
#   [GENIE=remix] bundle exec ruby reference/fuzz_eval_chars.rb [N] [seed]
# Modes: eval, evalbool, matchrecaps (Eval), evalmath (MathEval). Genie ERR:<x> vs our
# Lich::Genie::Error = same outcome (the repo golden spec's ERR tolerance). `count` is never
# generated (count(x, "") loops forever in Remix, Eval.cs:1315-1330 R) and matchre/replacere
# patterns are plain words (no catastrophic backtracking). Gate: fuzz_allowlist.tsv.
require_relative 'oracle_env'
OracleEnv.load_lich!
N = (ARGV[0] || 4000).to_i
SEED = (ARGV[1] || 7).to_i
srand(SEED)

EVAL_PIECES = ['"', '"', '(', ')', '(', ')', '!', '=', '<', '>', ',', '&', '|', '&&', '||', '==', '!=', '<>',
               '>=', '<=', ' ', ' ', ' ', "\t", '0', '1', '2', '9', '05', '.', '-', '1.5', 'a', 'x', 'Q', '%', '$',
               '#', '_', 'and', 'OR', 'not', 'true', 'False', 'eq', 'contains', 'instr', 'indexof', 'lastindexof',
               'match', 'startswith', 'endswith', 'replace', 'tolower', 'toupper', 'trim', 'len', 'length',
               'substr', 'substring', 'element', 'def', 'defined', 'Len', 'matchre', 'replacere',
               # non-ASCII: e-acute, sharp s, dotted I, dotless i, NBSP, an astral emoji (UTF-16 pair)
               *[0xE9, 0xDF, 0x130, 0x131, 0xA0, 0x1F600].map { |c| [c].pack('U') }].freeze
MATH_PIECES = ['1', '2', '3', '0', '9', '.', '5', '+', '-', '*', '/', '\\', '%', '^', '!', '&', '(', ')', ',', ' ',
               "\t", 'e', 'pi', 'x', '_', '#', '$', '=', 'sin', 'cos', 'sqrt', 'max', 'min', 'floor', 'ceiling',
               'log', 'log10', 'ln', 'round', 'abs', 'neg', 'pos', 'arctan', 'NaN', '1,000', '&H1F', 'E5',
               *[0x131, 0x17F, 0xE9].map { |c| [c].pack('U') }].freeze

def build(pieces, max)
  Array.new(rand(1..max)) { pieces.sample }.join
end

cases = []
N.times do
  e = build(EVAL_PIECES, 14)
  next if e.include?('count')

  cases << "eval\t#{e}" << "evalbool\t#{e}"
  cases << "matchrecaps\tmatchre(\"#{%w[abc a1b xyz].sample}\", \"#{%w[(b) a(.)c (x)(y)? \\d].sample}\") #{build(EVAL_PIECES, 5)}" if rand < 0.2
end
N.times { cases << "evalmath\t#{build(MATH_PIECES, 10)}" }
cases.uniq!
genie = OracleEnv.run(cases)
SEP = 0x1F.chr

def ours(mode, input)
  ev = Lich::Genie::Eval.new(globals: {})
  case mode
  when 'eval' then ev.eval_string(input)
  when 'evalbool' then ev.do_eval(input) ? '1' : '0'
  when 'matchrecaps'
    ev.eval_string(input)
    ([ev.result_list.length.to_s] + ev.result_list).join(SEP)
  when 'evalmath' then Lich::Genie::Numeric.format_double(Lich::Genie::MathEval.evaluate(input))
  end
rescue Lich::Genie::Error
  'RUBYERR:Lich::Genie::Error'
rescue StandardError => e
  "RUBYERR:#{e.class}"
end

diffs = []
cases.each_with_index do |line, i|
  mode, input = line.split("\t", 2)
  o = ours(mode, input)
  g = genie[i]
  next if o == g
  next if g.start_with?('ERR:') && o == 'RUBYERR:Lich::Genie::Error'

  diffs << [mode, input, o, g]
end
puts "fuzz_eval_chars vs #{OracleEnv::TREE}: #{cases.length} cases (seed #{SEED})"
exit OracleEnv.finish('fuzz_eval_chars', diffs, total: cases.length)
