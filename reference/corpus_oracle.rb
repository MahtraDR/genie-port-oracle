# frozen_string_literal: true

# Corpus-driven oracle golden (lab-side; promoted in WP0 from
# audits/2026-10-18/evidence/eval-math-text/corpus_diff.rb + corpus_math.rb and
# evidence/tests-tooling/harvest.rb).
#
# Harvests REAL expressions and regexes from the script corpus:
#   * `if/else if/while <cond>` conditions      -> evalbool
#   * `eval <var> <expr>`                        -> eval
#   * `evalmath <var> <expr>` / `#evalmath`      -> evalmath
#   * matchre/waitforre/action ... when/#trigger patterns -> eval matchre("", "<pattern>")
#     (compile-ability: does the pattern compile in .NET? in Ruby?)
# Variables are replaced by values from a fixed pool (3-4 deterministic variants per
# expression, crc32-seeded), as the original corpus_diff.rb did.
#
#   [GENIE=remix] bundle exec ruby reference/corpus_oracle.rb --record   # query genieoracle, write the golden
#   [GENIE=remix] [GENIE_TFM=net10.0|net8.0] bundle exec ruby reference/corpus_oracle.rb --check-oracle
#                                         # re-ask genieoracle for every golden row, print drift (no writes)
#   [GENIE=remix] bundle exec ruby reference/corpus_oracle.rb            # ours vs the frozen golden (no dotnet)
#   [GENIE=remix] bundle exec ruby reference/corpus_oracle.rb --accept   # re-baseline the accepted keys
#
# Golden: reference/goldens/corpus_oracle.<tree>.tsv, columns
#   mode  uses  source  src_expr  input  genie
# Gate = EXACT KEYS (OracleEnv.finish header): every diff must be listed, with the same ours
# value, in reference/goldens/corpus_oracle.accepted.<tree>.tsv, else exit 1; the allowlist
# (`corpus_oracle` lines) only tags keys at --accept time. Re-record the golden => re-accept.
# The repo's curated subset (spec/fixtures/genie/oracle/) is cut from this
# golden by reference/curate_oracle_golden.rb.
require 'zlib'
require_relative 'oracle_env'
OracleEnv.load_lich!

module CorpusOracle
  # CORPUS_DIR (the corpus behind the lab golden is private; resolved lazily so --check-oracle and
  # curate_oracle_golden.rb --check-fixture run without it)
  def self.dirs = LabPaths.corpora!.values
  POOL = ['0', '1', '5', '10', '-1', '', 'sword', 'steel sword', 'a|b|c', 'Empty', '2.5'].freeze
  MATH_POOL = ['0', '1', '5', '10', '-1', '2.5', '100'].freeze
  VAR = /(?:%|\$)[A-Za-z_][\w.]*(?:\((?:\d+|%[\w.]+)\))?|\$\d+/
  GOLDEN = File.join(__dir__, 'goldens', "corpus_oracle.#{OracleEnv::TREE}.tsv")
  FIELDS = %w[mode uses source src_expr input genie].freeze

  module_function

  def harvest
    exprs = Hash.new(0)
    src = {}
    dirs.each do |d|
      Dir.glob("#{d}/**/*.{cmd,inc}").sort.each do |f|
        File.foreach(f, encoding: 'binary') do |raw|
          l = raw.force_encoding('utf-8').scrub('?').strip
          key = classify(l)
          next if key.nil? || key[1].to_s.empty? || key[1].include?("\t")

          exprs[key] += 1
          src[key] ||= "#{File.basename(d)}/#{File.basename(f)}"
        end
      end
    end
    [exprs, src]
  end

  def classify(line)
    if (m = line.match(/\A(?:if|else\s+if|elseif|while)\s+(.*)\z/i))
      e = m[1]
      i = e.downcase.index(' then')
      e = e[0...i] if i
      ['evalbool', e.sub(/\s+do\s*\z/i, '')]
    elsif (m = line.match(/\Aeval\s+\S+\s+(.*)\z/i)) then ['eval', m[1]]
    elsif (m = line.match(/\A#?evalmath\s+\S+\s+(.*)\z/i)) then ['evalmath', m[1]]
    elsif (pat = regex_of(line)) then ['regex', pat]
    end
  end

  def regex_of(line)
    p = if line =~ /\A(?:matchre\s+\S+|waitforre)\s+(.+)\z/i then Regexp.last_match(1)
        elsif line =~ /\Aaction\b.*?\bwhen\s+(.+)\z/i then Regexp.last_match(1)
        elsif line =~ /#trigger\s+\{([^{}]*)\}/i then Regexp.last_match(1)
        end
    return nil unless p

    p = p.strip.sub(%r{\A/(.*)/i?\z}, '\1')
    return nil if p.empty? || p.include?('"') || (p =~ /[%$@][A-Za-z]/ && p =~ /%[A-Za-z]/)

    p
  end

  def cases
    exprs, src = harvest
    out = []
    exprs.each do |(mode, e), uses|
      if mode == 'regex'
        out << ['regex', uses, src[[mode, e]], e, e]
        next
      end
      pool = mode == 'evalmath' ? MATH_POOL : POOL
      (0..2).each do |s|
        x = e.gsub(VAR) { |v| pool[Zlib.crc32(v + s.to_s) % pool.size] }
        out << [mode, uses, src[[mode, e]], e, x] unless x.include?("\n")
      end
    end
    out.uniq { |c| [c[0], c[4]] }
  end

  def oracle_line(mode, input)
    mode == 'regex' ? %(eval\tmatchre("", "#{input}")) : "#{mode}\t#{input}"
  end

  def record
    cs = cases
    # count(x, "") loops forever inside Genie's Eval.cs; keep it out of the batch.
    cs.reject! { |c| c[4] =~ /count\([^)]*,\s*""\s*\)/ }
    g = OracleEnv.run(cs.map { |mode, _u, _s, _e, x| oracle_line(mode, x) })
    Dir.mkdir(File.dirname(GOLDEN)) unless Dir.exist?(File.dirname(GOLDEN))
    File.open(GOLDEN, 'w') do |f|
      f.puts "# corpus_oracle golden vs #{OracleEnv::TREE} (#{OracleEnv::ORACLE}); #{FIELDS.join("\t")}"
      cs.each_with_index { |(mode, u, s, e, x), i| f.puts [mode, u, s, e, x, g[i]].join("\t") }
    end
    puts "recorded #{cs.length} cases -> #{GOLDEN}"
    0
  end

  # --check-oracle: re-ask the live genieoracle (GENIE / GENIE_TFM build) for every frozen golden
  # row and print the rows whose answer differs from the golden (golden drift, e.g. after a .NET
  # runtime change). Writes nothing; exit 1 on any drift.
  def check_oracle
    rows = load_golden.reject { |r| r['input'] =~ /count\([^)]*,\s*""\s*\)/ }
    g = OracleEnv.run(rows.map { |r| oracle_line(r['mode'], r['input']) })
    drift = rows.each_with_index.reject { |r, i| r['genie'] == g[i] }
    puts "  [corpus_oracle --check-oracle vs #{OracleEnv::TREE} #{OracleEnv::TFM}] rows=#{rows.length} drift=#{drift.length}"
    drift.each do |r, i|
      puts "    DRIFT #{r['mode']} #{r['source']} input=#{r['input'].inspect} golden=#{r['genie'].inspect} live=#{g[i].inspect}"
    end
    drift.empty? ? 0 : 1
  end

  def load_golden
    abort "no golden #{GOLDEN}: run with --record" unless File.exist?(GOLDEN)
    File.readlines(GOLDEN, chomp: true).reject { |l| l.start_with?('#') }.map { |l| FIELDS.zip(l.split("\t", -1)).to_h }
  end

  # Our engine's answer in the oracle's output format.
  def ours(mode, input)
    ev = Lich::Genie::Eval.new(globals: {})
    case mode
    when 'evalbool' then ev.do_eval(input) ? '1' : '0'
    when 'eval' then ev.eval_string(input)
    when 'evalmath' then Lich::Genie::Numeric.format_double(Lich::Genie::MathEval.evaluate(input))
    when 'regex' then regex_ours(input)
    end
  rescue Lich::Genie::Error
    # Eval::Fault (WP8: what .NET throws inside Eval.cs) and MathEval's Error alike.
    'RUBYERR:Lich::Genie::Error'
  rescue StandardError => e
    "RUBYERR:#{e.class}"
  end

  # The oracle evaluates matchre("", pat): "1"/"0" = does the compiled pattern match the
  # empty subject, ERR = .NET cannot compile it. Ours: the same question asked of the
  # engine's script-pattern compiler (NetRegex, used by matchre/waitforre/action/#trigger
  # since WP2; before WP2 this asked raw Regexp.new).
  def regex_ours(pattern)
    Lich::Genie::NetRegex.compile(pattern).match?('') ? '1' : '0'
  rescue StandardError
    'ERR:RegexParseException'
  end

  def same?(mode, ours, genie)
    return true if ours == genie
    # Both reject the expression (the repo golden spec's ERR TOLERANCE): Genie's EvalMath
    # catch sets the var to "0" (Script.cs:3214-3269 R), an Eval exception reaches
    # GenieError (G46 decision: ours stops the script); ours raises Lich::Genie::Error.
    return true if genie.start_with?('ERR:') && ours == 'RUBYERR:Lich::Genie::Error'
    return false unless mode == 'evalmath'

    a = OracleEnv.parse_double(ours)
    b = OracleEnv.parse_double(genie)
    a && b && OracleEnv.same_double?(a, b)
  end

  def compare(accept: false)
    rows = load_golden
    diffs = []
    rows.each do |r|
      o = ours(r['mode'], r['input'])
      g = r['genie'].start_with?('ERR') && r['mode'] == 'regex' ? 'ERR:RegexParseException' : r['genie']
      diffs << [r['mode'], r['input'], o, r['genie']] unless same?(r['mode'], o, g)
    end
    counts = rows.group_by { |r| r['mode'] }.transform_values(&:length)
    puts "corpus_oracle vs #{OracleEnv::TREE} golden: #{rows.length} cases #{counts}"
    OracleEnv.finish('corpus_oracle', diffs, total: rows.length, accepted: OracleEnv.accepted_path('corpus_oracle'), accept: accept)
  end
end

if $PROGRAM_NAME == __FILE__
  $VERBOSE = nil # corpus regexes trip Ruby's 'nested repeat' / unescaped ']' warnings
  exit(if ARGV.include?('--record') then CorpusOracle.record
       elsif ARGV.include?('--check-oracle') then CorpusOracle.check_oracle
       else CorpusOracle.compare(accept: ARGV.include?('--accept'))
       end)
end
