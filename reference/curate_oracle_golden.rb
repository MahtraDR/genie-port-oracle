# frozen_string_literal: true

# Cut the CURATED oracle golden that lives in the lich-5 repo as a dotnet-free rspec fixture
# (spec/fixtures/genie/oracle/eval_golden.tsv, checked by spec/lib/genie/eval_oracle_golden_spec.rb).
#
#   GENIE=remix bundle exec ruby reference/curate_oracle_golden.rb [--write]
#   GENIE=remix [GENIE_TFM=net10.0|net8.0] bundle exec ruby reference/curate_oracle_golden.rb --check-fixture
#     (read-only: re-ask genieoracle for every fixture row, print rows whose frozen answer drifted)
#
# Sources (deterministic):
#   * reference/goldens/corpus_oracle.remix.tsv (run corpus_oracle.rb --record first): for every
#     Eval.cs function and operator, the most-used corpus rows containing it, plus a fixed-seed
#     sample of other conditions/evals/evalmath rows and harvested regexes (as matchre("", p)).
#   * SYNTHETIC rows for what the corpus does not reach: every MathEval function/operator,
#     NaN/Infinity, mixed-case AND/OR/NOT, function-&&-comparison (t41 shapes), matchre
#     capture groups (matchrecaps).
# Every row is answered LIVE by genieoracle (Remix Eval.cs/MathEval.cs). Rows where our engine
# currently differs get a finding id from the first NARROW reference/fuzz_allowlist.tsv entry
# (among curated / corpus_oracle / fuzz_eval_grammar / fuzz_oracle / fuzz_eval / fuzz_regex), else
# from the row's exact key in reference/goldens/corpus_oracle.accepted.<tree>.tsv; the spec marks
# them pending (ratchet). UMBRELLA entries (input regex `/./`, OracleEnv::UMBRELLA_SOURCES) never
# tag a row: a differing row that only an umbrella explains aborts curation, so a regression
# cannot be re-curated into a pending row.
# Only ASCII rows are kept (the fixture is diffed and reviewed as text), except the synthetic
# U+221E rows (WP8-r1 parity B1), whose only non-ASCII character is that sign.
require_relative 'corpus_oracle'

module Curate
  FIXTURE = File.join(OracleEnv::LICH, 'spec/fixtures/genie/oracle/eval_golden.tsv')
  EVAL_FUNCS = %w[contains count def defined element endswith indexof instr instring lastindexof len length
                  match matchre replace replacere startswith substr substring tolower toupper trim].freeze
  EVAL_OPS = ['&&', '||', '!=', '<>', '>=', '<=', '==', ' = ', ' > ', ' < ', '!', ' and ', ' or ', ' not '].freeze
  PER_TOKEN = 3
  SAMPLE = { 'evalbool' => 90, 'eval' => 25, 'evalmath' => 25, 'regex' => 40 }.freeze

  MATH = ['sin(0)', 'cos(0)', 'tan(0)', 'arcsin(1)', 'arccos(1)', 'arctan(1)', 'sqrt(16)', 'max(2, 3)', 'min(2, 3)',
          'floor(2.5)', 'ceiling(2.1)', 'log(100)', 'log10(1000)', 'ln(1)', 'round(2.5)', 'round(3.5)', 'abs(-3)',
          'neg(3)', 'pos(3)', 'e', 'pi', '7 - 2', '7 + 2', '7 * 2', '7 / 2', '7 \\ 2', '7 % 2', '2 ^ 10', '5!', '-(3)',
          '+(3)', '(1 + 2) * 3', '1 + 2 * 3', '2 ^ 3 ^ 2', '-2 ^ 2', '10 % 3 * 2', '0.1 + 0.2', '1e3', '3x',
          'sqrt(-1)', 'ln(0)', '1 / 0', '-1 / 0', '0 / 0', '10 \\ 0', '7 \\ 2.5', 'round(2.567, 2)', '20!', '171!',
          # `&` is a LEVEL5 operator with no calc_op case (MathEval.cs:113-117, 157-240 R);
          # IsNumeric fast path (MathEval.cs:146-147 R); chained postfix factorial.
          '2 & 3', '2&3', '1 + 2 & 3', 'NaN', '1,000', '3!!',
          # WP8-r1 parity 2/3: Math.Pow(-Infinity, non-integer) and fmod with an infinite dividend.
          'neg(1 / 0) ^ 0.5', 'neg(1 / 0) ^ -0.5', 'neg(1 / 0) ^ 1.5', 'neg(1 / 0) ^ -3', '(1 / 0) % neg(1 / 0)',
          'neg(1 / 0) % (1 / 0)', '3 % (1 / 0)'].freeze
  EVALMATH = ['10 / 4', '1 / 3', '2 ^ 0.5', '100000 * 100000', '0.000001 * 1', '1 / 0', 'sqrt(-1)', '5 - 5', '-0',
              '123456789 * 1000', '1 + 2 + 3', '2 & 3', '1,000'].freeze
  # MathEval m_funcs (MathEval.cs:63 R) and operator tokens (MathEval.cs:69-138 R): every one
  # must appear in a math/evalmath row (also asserted by the repo spec).
  MATH_FUNCS = %w[sin cos tan arcsin arccos arctan sqrt max min floor ceiling log log10 ln round abs neg pos].freeze
  MATH_OPS = ['-', '+', '*', '/', '\\', '%', '^', '!', '&', '(', ')'].freeze
  BOOL = ['1 = 1 AND 2 = 3', '1 = 1 and 2 = 3', '1 = 2 OR 2 = 2', '1 = 2 or 2 = 2', 'NOT 1 = 2', 'not 1 = 2',
          '1 = 1 And 2 = 2', '1 = 2 Or 3 = 3', 'Not 1 = 1', 'NOT (5 = 5)', '5 > 1 AND 5 < 10', '5 > 10 OR 5 = 5',
          'contains("abc", "b") && 5 = 6', '5 = 6 && contains("abc", "b")', 'contains("abc", "z") || 5 = 5',
          'contains("abc", "b") and contains("xyz", "q")', '5 = 5 && "abc" = "abd"', 'contains("abc", "b") && 2 = 1',
          '5 && 2 = 5', '5 || 9 = 5', 'startswith("abc", "a") && len("ab") = 2', 'len("ab") = 2 || 1 = 0',
          'TRUE', 'true', 'FALSE', '1 EQ 1', '1 eq 2', '"abc" = "ABC"', '"abc" == "abc"', '"b" > "a"', '10 > 9',
          '"10" > "9"', '2.5 >= 2.5', '-1 < 0', '1 <> 2', '!1', '!0', '!"abc"', '!""', '""', '"1"', '0', '1',
          '(1 = 1) && ((2 = 2) || (3 = 4))', '((1 = 2))', 'def(nosuchvar)', 'defined(nosuchvar)', '!def(nosuchvar)',
          # WP8-r1 engineering NB6: chained comparisons (GetBooleanResult over the pass's sections)
          '1 = 1 = 0', '1 < 2 < 1'].freeze
  # WP8-r1 parity B1: U+221E is an IsNumeric char (Eval.cs:205 R) and a signed one is an infinity
  # to StringToDouble (Eval.cs:656-657 R). The only non-ASCII rows of the fixture (built from the
  # codepoint; {run} keeps them although they are not ASCII).
  INF = [0x221E].pack('U')
  INF_ROWS = [['evalbool', "#{INF} > 1"], ['evalbool', "-#{INF} < 0"], ['evalbool', "#{INF} > 999999"],
              ['evalbool', "-#{INF} < -999999"], ['evalbool', "-#{INF} = -#{INF}"], ['evalbool', "#{INF} >= #{INF}"],
              ['evalbool', "--#{INF} < 0"], ['evalbool', "1#{INF} > 0"], ['evalbool', "#{INF}- > 1"], ['evalbool', ".#{INF} > 0"],
              ['evalbool', "+#{INF} > 1"], ['evalbool', "-#{INF} > -999999"], ['evalbool', INF], ['eval', "1#{INF}1"],
              ['eval', "-#{INF}"], ['eval', "#{INF} > 1"]].freeze
  EVALS = ['element("a|b|c", 1)', 'element("a|b|c", 5)', 'count("a|b|c", "|")', 'instring("abc", "b")',
           'replace("a-b-c", "-", "+")', 'replacere("a1b22", "\\d+", "#")', 'substr("abcdef", 2, 3)',
           'substring("abcdef", 2)', 'tolower("AbC")', 'toupper("aBc")', 'trim("  x  ")', 'len("")', 'length("abc")',
           'indexof("abcabc", "c")', 'lastindexof("abcabc", "c")', 'match("abc", "b")', 'matchre("abc", "^a")',
           'endswith("abc", "c")', 'startswith("abc", "b")', 'contains("a|b", "|")', 'instr("abc", "c")',
           # WP8-r1 engineering NB6: a lone unterminated quote is kept as text
           '"'].freeze
  CAPS = ['matchre("You hit the troll hard", "^You (\\w+) the (\\w+)")', 'matchre("HP: 42/100", "(\\d+)/(\\d+)")',
          'matchre("abc", "(x)?abc")', 'matchre("The orc dies.", "^The (\\w+) (\\w+)\\.$")',
          'matchre("no match here", "(\\d+)")'].freeze
  FUZZERS = %w[curated corpus_oracle fuzz_eval_grammar fuzz_oracle fuzz_eval fuzz_regex].freeze

  module_function

  def ascii?(text) = text.ascii_only? && !text.include?("\t")

  def pick_corpus
    rows = CorpusOracle.load_golden.select { |r| ascii?(r['input']) && ascii?(r['genie']) }
    by_mode = rows.group_by { |r| r['mode'] }
    chosen = []
    %w[evalbool eval].each do |m|
      ranked = by_mode.fetch(m, []).sort_by { |r| [-r['uses'].to_i, r['input']] }
      (EVAL_FUNCS.map { |f| /\b#{f}\(/ } + EVAL_OPS.map { |o| Regexp.new(Regexp.escape(o)) }).each do |re|
        chosen.concat(ranked.select { |r| re.match?(r['input']) }.first(PER_TOKEN))
      end
    end
    rng = Random.new(20_261_018)
    SAMPLE.each { |m, n| chosen.concat(by_mode.fetch(m, []).sort_by { |r| [r['input']] }.sample(n, random: rng)) }
    chosen.uniq { |r| [r['mode'], r['input']] }.map do |r|
      r['mode'] == 'regex' ? ['eval', %(matchre("", "#{r['input']}")), "corpus regex #{r['source']}"] : [r['mode'], r['input'], "corpus #{r['source']}"]
    end
  end

  def synthetic
    MATH.map { |e| ['math', e, 'synthetic MathEval'] } + EVALMATH.map { |e| ['evalmath', e, 'synthetic evalmath'] } +
      BOOL.map { |e| ['evalbool', e, 'synthetic Eval'] } + EVALS.map { |e| ['eval', e, 'synthetic Eval'] } +
      CAPS.map { |e| ['matchrecaps', e, 'synthetic captures'] } +
      INF_ROWS.map { |m, e| [m, e, 'synthetic U+221E'] }
  end

  # Ours, in genieoracle's output format (same convention as the repo spec).
  def ours(mode, input)
    globals = Object.new.tap { |g| g.define_singleton_method(:key?) { |_| false } }
    ev = Lich::Genie::Eval.new(globals: globals)
    case mode
    when 'evalbool' then ev.do_eval(input) ? '1' : '0'
    when 'eval' then ev.eval_string(input)
    when 'math' then Lich::Genie::MathEval.evaluate(input)
    when 'evalmath' then Lich::Genie::Numeric.format_double(Lich::Genie::MathEval.evaluate(input))
    when 'matchrecaps'
      ev.eval_string(input)
      ([ev.result_list.length.to_s] + ev.result_list).join("\x1f")
    end
  rescue StandardError => e
    "RUBYERR:#{e.class}"
  end

  def same?(mode, ours, genie)
    return true if genie.start_with?('ERR:') && ours.to_s.start_with?('RUBYERR:')
    return OracleEnv.same_double?(ours, OracleEnv.parse_double(genie)) if mode == 'math'

    ours.to_s == genie
  end

  # Order: narrow `curated` entries, then the row's exact corpus_oracle accepted key (tagged by
  # the corpus triage). A corpus row that is not an accepted key matched Remix at --accept time,
  # so a diff there is a regression: nothing else may tag it. Synthetic rows may also be tagged
  # by the other fuzzers' narrow entries.
  def finding_for(mode, input, genie, corpus:)
    e = OracleEnv.allowed('curated', mode, input, genie, narrow: true)
    return e.finding if e

    hit = corpus_accepted[corpus_key(mode, input)]
    return hit['finding'] if hit
    return nil if corpus

    FUZZERS.drop(1).each do |f|
      e = OracleEnv.allowed(f, mode, input, genie, narrow: true)
      return e.finding if e
    end
    nil
  end

  def corpus_accepted
    @corpus_accepted ||= OracleEnv.load_accepted(OracleEnv.accepted_path('corpus_oracle')) ||
                         abort('no corpus_oracle accepted keys: run corpus_oracle.rb --accept first')
  end

  # A curated `matchre("", "<p>")` row is the corpus `regex` row for <p>.
  def corpus_key(mode, input)
    m = mode == 'eval' && input.match(/\Amatchre\("", "(.*)"\)\z/)
    m ? ['regex', m[1]] : [mode, input]
  end

  def run(write:)
    rows = (pick_corpus + synthetic).uniq { |m, i, _| [m, i] }
    rows.reject! { |_m, i, _| i =~ /count\([^)]*,\s*""\s*\)/ }
    genie = OracleEnv.run(rows.map { |m, i, _| "#{m}\t#{i}" })
    out = []
    unexplained = []
    rows.each_with_index do |(m, i, src), k|
      g = genie[k]
      next unless ascii?(g) || (src == 'synthetic U+221E' && !g.include?("\t"))

      o = ours(m, i)
      finding = same?(m, o, g) ? '' : finding_for(m, i, g, corpus: src.start_with?('corpus'))
      unexplained << [m, i, o, g] if finding.nil?
      out << [m, i, g.gsub("\x1f", '\x1f'), finding.to_s, src]
    end
    puts "curated #{out.length} rows (#{out.count { |r| !r[3].empty? }} pending) from #{rows.length} candidates"
    out.group_by { |r| r[0] }.each { |m, rs| puts "  #{m}: #{rs.length}" }
    missing = (EVAL_FUNCS.map { |f| "#{f}(" } + %w[&& || != <> >= <= == AND OR NOT]).reject { |t| out.any? { |r| r[1].include?(t) } }
    maths = out.select { |r| %w[math evalmath].include?(r[0]) }.map { |r| r[1] }
    missing += MATH_FUNCS.map { |f| "math #{f}(" }.reject { |t| maths.any? { |i| i.match?(/\b#{t[5..-2]}\(/) } }
    missing += MATH_OPS.map { |o| "math #{o}" }.reject { |t| maths.any? { |i| i.include?(t[5..]) } }
    puts "  coverage gaps: #{missing.inspect}"
    unless missing.empty?
      puts '  --write refused: every Eval/MathEval function and operator needs a row'
      return 1
    end
    unless unexplained.empty?
      unexplained.each { |m, i, o, g| puts "  UNEXPLAINED #{m} #{i.inspect} ours=#{o.inspect} genie=#{g.inspect}" }
      return 1
    end
    return 0 unless write

    File.write(FIXTURE, header + out.map { |r| r.join("\t") }.join("\n") + "\n")
    puts "wrote #{FIXTURE} (#{File.size(FIXTURE)} bytes)"
    0
  end

  # --check-fixture: re-ask the live genieoracle (GENIE / GENIE_TFM build) for every row of the
  # repo fixture and print the rows whose frozen genie column differs (golden drift, e.g. after a
  # .NET runtime change). Read-only: never writes the fixture. Exit 1 on any drift.
  def check_fixture
    rows = File.readlines(FIXTURE, chomp: true).reject { |l| l.start_with?('#') || l.empty? }.map { |l| l.split("\t", -1) }
    genie = OracleEnv.run(rows.map { |m, i, *| "#{m}\t#{i}" })
    drift = rows.each_with_index.reject { |(_m, _i, g), k| g == genie[k].gsub("\x1f", '\x1f') }
    puts "  [curate --check-fixture vs #{OracleEnv::TREE} #{OracleEnv::TFM}] rows=#{rows.length} drift=#{drift.length}"
    drift.each do |(m, i, g, f), k|
      puts "    DRIFT #{m} #{i.inspect} fixture=#{g.inspect} live=#{genie[k].inspect} finding=#{f.inspect}"
    end
    drift.empty? ? 0 : 1
  end

  def header
    <<~HDR
      # Curated Genie4 Remix v4.2.4 oracle golden (genieoracle = Remix Eval.cs + MathEval.cs, headless).
      # Generated by reference/curate_oracle_golden.rb (GENIE=remix); do not hand-edit
      # expected values. Columns: mode<TAB>input<TAB>genie<TAB>finding<TAB>source
      #   mode: evalbool (Eval.DoEval -> 1/0) | eval (Eval.EvalString) | math (MathEval.Evaluate, "R")
      #         | evalmath (Command.cs EvalMath string) | matchrecaps (count + capture groups joined by
      #         the 4-character text \\x1f, standing for the oracle's 0x1F unit separator)
      #   genie: ERR:<Exception> = Genie threw; ours raising counts as the same outcome.
      #   finding: non-empty = our engine currently differs; the spec marks the row pending (ratchet).
    HDR
  end
end

if $PROGRAM_NAME == __FILE__
  exit(ARGV.include?('--check-fixture') ? Curate.check_fixture : Curate.run(write: ARGV.include?('--write')))
end
