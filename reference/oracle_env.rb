# frozen_string_literal: true

# Shared plumbing for the genieoracle-backed fuzzers and corpus tools.
#
#   GENIE=remix (default; Genie4 Remix v4.2.4, the parity target) | GENIE=upstream
#   GENIE_TFM=net10.0 (default; the runtime Remix v4.2.4 ships on) | GENIE_TFM=net8.0 (legacy baseline)
#
# select which genieoracle build is used (oracle/bin/<tree>/Release/<tfm>, built by
# GENIE=<tree> GENIE_TFM=<tfm> oracle/build.sh). Every fuzzer reports through OracleEnv.finish, which exits 1 when any
# diff is NOT covered by reference/fuzz_allowlist.tsv (tree-specific entries allowed).
#
# EXACT-KEY RATCHET: a fuzzer that passes `accepted:` (a reference/goldens/*.accepted.<tree>.tsv
# path) is gated by that file instead of the allowlist: every diff must be an accepted
# (mode, input) key with the SAME ours value, else exit 1 (NEW = a key that did not diverge
# before, CHANGED = our wrong answer changed). Accepted keys that now match are reported as
# STALE (remove them with --accept). `--accept` rewrites the file from the current diffs, each
# tagged with its first allowlist finding (a diff no entry explains aborts), and prints what
# was added/removed. UMBRELLA allowlist entries (input regex that matches everything: `/./`,
# `/\A/`) cannot catch a regression inside their bucket, so a run gated by them prints a warning
# and curate_oracle_golden.rb never tags a row from them.
require 'open3'
require_relative 'lab_paths'

module OracleEnv
  ROOT = LabPaths::ROOT # this repository (oracle/, flow-oracle/, reference/)
  LICH = LabPaths.lich  # LICH_WORKTREE; default: a `lich-5` directory next to this repository
  TREE = ENV.fetch('GENIE', 'remix')
  abort "GENIE must be remix|upstream (got #{TREE})" unless %w[remix upstream].include?(TREE)
  TFM = ENV.fetch('GENIE_TFM', 'net10.0')
  abort "GENIE_TFM must be net10.0|net8.0 (got #{TFM})" unless %w[net10.0 net8.0].include?(TFM)
  DOTNET = LabPaths.dotnet # $DOTNET, else $DOTNET_ROOT/dotnet, else `dotnet` on PATH
  ORACLE = LabPaths.oracle_dll(TREE, TFM).freeze
  ALLOWLIST = File.join(__dir__, 'fuzz_allowlist.tsv')
  abort "genieoracle not built for #{TREE} #{TFM}: run GENIE=#{TREE} GENIE_TFM=#{TFM} #{ROOT}/oracle/build.sh" unless File.exist?(ORACLE)

  # .NET prints infinity as "Infinity" (InvariantCulture, `math`) or U+221E (en-US,
  # `evalmath`); written as a code point so this file stays ASCII.
  INF = [0x221E].pack('U')

  module_function

  def load_lich!
    $LOAD_PATH.unshift(File.join(LICH, 'lib'))
    require 'genie'
  end

  # Run "<mode>\t<input>" lines through genieoracle --stdin; one output line per input.
  def run(lines)
    out, err, st = Open3.capture3(DOTNET, ORACLE, '--stdin', stdin_data: lines.join("\n"))
    abort "genieoracle failed (#{st}): #{err}" unless st.success?
    g = out.split("\n", -1)
    g.pop if g.last == ''
    abort "genieoracle count mismatch #{g.length} vs #{lines.length}" unless g.length == lines.length
    dump(lines, g)
    g
  end

  # Open3.capture3 of genieoracle --stdin over +stdin+ (one request per line), dumped like {#run}.
  # @return [Array(String, String, Process::Status)]
  def capture3(stdin)
    out, err, st = Open3.capture3(DOTNET, ORACLE, '--stdin', stdin_data: stdin)
    answers = out.split("\n", -1)
    answers.pop if answers.last == ''
    dump(stdin.split("\n", -1), answers) if st.success?
    [out, err, st]
  end

  # ORACLE_DUMP=<file>: append every "<request>\t=> <answer>" pair (String#dump-escaped) to the file,
  # so two runs of the same seeded tool under GENIE_TFM=net8.0 / net10.0 can be diffed row by row
  # (a runtime change shows up even where both answers diverge from ours).
  def dump(lines, answers)
    path = ENV.fetch('ORACLE_DUMP', nil)
    return if path.nil? || path.empty?

    File.open(path, 'a') { |f| lines.each_with_index { |l, i| f.puts "#{l.dump}\t=> #{answers[i].to_s.dump}" } }
  end

  # Parse a genieoracle double. NaN and both infinity spellings are VALUES, not errors
  # (T01: fuzz_oracle used to file 137 NaN/Inf results as "one-side errors").
  # @return [Float, nil] nil when the text is not a number (e.g. "ERR:...")
  def parse_double(text)
    s = text.to_s.strip
    case s
    when 'NaN', '-NaN' then Float::NAN
    when 'Infinity', '+Infinity', INF, "+#{INF}" then Float::INFINITY
    when '-Infinity', "-#{INF}" then -Float::INFINITY
    else Float(s, exception: false)
    end
  end

  # Float equality for oracle comparisons: NaN == NaN, infinities by sign, else 1e-9 rel.
  def same_double?(ours, genie)
    return false unless ours.is_a?(Numeric) && genie.is_a?(Numeric)
    return ours.to_f.nan? && genie.nan? if ours.to_f.nan? || genie.nan?
    return ours == genie if ours.to_f.infinite? || genie.infinite?

    (ours - genie).abs <= 1e-9 * [1.0, ours.abs, genie.abs].max
  end

  # Input regexes that match every input: such an entry is an umbrella, not an allowlist.
  UMBRELLA_SOURCES = ['.', '\\A', ''].freeze

  Entry = Struct.new(:fuzzer, :tree, :mode, :regex, :genie_regex, :finding, :note, :hits) do
    def umbrella? = UMBRELLA_SOURCES.include?(regex.source)
  end

  # reference/fuzz_allowlist.tsv, TAB-separated:
  #   fuzzer  tree  mode  /regex on input/  /regex on genie output/|*  finding  note
  # (`*` = any fuzzer/tree/mode/output). A diff is allowed when both regexes match.
  def allowlist
    @allowlist ||= File.readlines(ALLOWLIST, chomp: true).filter_map do |l|
      next if l.strip.empty? || l.start_with?('#')

      f, t, m, re, gre, finding, note = l.split("\t", 7)
      raise "#{ALLOWLIST}: bad line #{l.inspect}" unless re&.start_with?('/') && gre && finding

      Entry.new(f, t, m, slash_regex(re), gre == '*' ? nil : slash_regex(gre), finding, note.to_s, 0)
    end
  end

  def slash_regex(text) = Regexp.new(text[1...text.rindex('/')])

  # @param narrow [Boolean] skip umbrella entries
  def allowed(fuzzer, mode, input, genie, narrow: false)
    allowlist.find do |e|
      next false if narrow && e.umbrella?

      [fuzzer, '*'].include?(e.fuzzer) && [TREE, '*'].include?(e.tree) && [mode, '*'].include?(e.mode) &&
        e.regex.match?(input) && (e.genie_regex.nil? || e.genie_regex.match?(genie.to_s))
    end
  end

  # reference/goldens/<name>.accepted.<tree>.tsv
  def accepted_path(name) = File.join(__dir__, 'goldens', "#{name}.accepted.#{TREE}.tsv")

  ACCEPTED_FIELDS = %w[mode input ours genie finding].freeze

  # @return [Hash{Array(mode, input) => Hash}, nil] nil when the file does not exist.
  #   input/ours/genie are stored String#dump-escaped (one line per key, any bytes).
  def load_accepted(path)
    return nil unless File.exist?(path)

    File.readlines(path, chomp: true).reject { |l| l.start_with?('#') || l.empty? }.to_h do |l|
      mode, input, ours, genie, finding = l.split("\t", -1)
      [[mode, input.undump], { 'ours' => ours.undump, 'genie' => genie.undump, 'finding' => finding }]
    end
  end

  # @param diffs [Array<Array(mode, input, ours, genie)>]
  # @param accepted [String, nil] exact-key ratchet file (see header); nil = allowlist gate
  # @param accept [Boolean] rewrite +accepted+ from +diffs+ instead of checking
  # @return [Integer] process exit status: 0 when every diff is accepted / allowlisted
  def finish(fuzzer, diffs, total:, accepted: nil, accept: false)
    return write_accepted(fuzzer, diffs, accepted) if accept && accepted

    set = accepted && load_accepted(accepted)
    return finish_exact(fuzzer, diffs, set, total, accepted) if set

    puts "  [#{fuzzer}] no accepted-key file #{accepted}: allowlist gate only" if accepted
    finish_allowlist(fuzzer, diffs, total)
  end

  def finish_allowlist(fuzzer, diffs, total)
    unexplained = diffs.reject do |mode, input, _o, g|
      (e = allowed(fuzzer, mode, input, g)) && (e.hits += 1)
    end
    puts "  [#{fuzzer} vs #{TREE}] cases=#{total} diffs=#{diffs.length} allowlisted=#{diffs.length - unexplained.length} UNEXPLAINED=#{unexplained.length}"
    allowlist.select { |e| e.hits.positive? }.each { |e| puts format('    allow %-6s %5d  %s %s', e.finding, e.hits, e.regex.source[0, 50], e.note[0, 60]) }
    unexplained.first(30).each do |mode, input, o, g|
      puts format('    UNEXPLAINED %-10s %-44s ours=%-18s genie=%s', mode, input.inspect[0, 44], o.inspect[0, 18], g.inspect[0, 30])
    end
    puts "    ... #{unexplained.length - 30} more" if unexplained.length > 30
    umbrellas = allowlist.select { |e| e.hits.positive? && e.umbrella? }
    unless umbrellas.empty?
      puts "    WARNING: #{umbrellas.sum(&:hits)} diffs passed only through UMBRELLA entries " \
           "(#{umbrellas.map(&:finding).uniq.join(', ')}); a regression inside those buckets cannot fail this run"
    end
    unexplained.empty? ? 0 : 1
  end

  def finish_exact(fuzzer, diffs, set, total, path)
    seen = {}
    fresh = []
    changed = []
    diffs.each do |mode, input, o, g|
      key = [mode, input]
      seen[key] = true
      row = set[key]
      if row.nil? then fresh << [mode, input, o, g]
      elsif row['ours'] != o.to_s then changed << [mode, input, o, row['ours']]
      end
    end
    stale = set.keys.reject { |k| seen[k] }
    accepted_n = diffs.length - fresh.length - changed.length
    puts "  [#{fuzzer} vs #{TREE}] cases=#{total} diffs=#{diffs.length} accepted=#{accepted_n} NEW=#{fresh.length} " \
         "CHANGED=#{changed.length} STALE=#{stale.length} (exact keys: #{File.basename(path)})"
    set.values_at(*(seen.keys & set.keys)).group_by { |r| r['finding'] }.sort.each do |f, rs|
      puts format('    accepted %-6s %5d', f, rs.length)
    end
    fresh.first(30).each do |mode, input, o, g|
      puts format('    NEW       %-10s %-44s ours=%-18s genie=%s', mode, input.inspect[0, 44], o.inspect[0, 18], g.inspect[0, 30])
    end
    changed.first(30).each do |mode, input, o, was|
      puts format('    CHANGED   %-10s %-44s ours=%-18s was=%s', mode, input.inspect[0, 44], o.inspect[0, 18], was.inspect[0, 30])
    end
    stale.first(10).each { |mode, input| puts format('    STALE (now matches; --accept to drop) %-10s %s', mode, input.inspect[0, 60]) }
    fresh.empty? && changed.empty? ? 0 : 1
  end

  def write_accepted(fuzzer, diffs, path)
    rows = diffs.map do |mode, input, o, g|
      e = allowed(fuzzer, mode, input, g)
      [mode, input, o.to_s, g.to_s, e&.finding]
    end
    unexplained = rows.select { |r| r[4].nil? }
    unless unexplained.empty?
      unexplained.first(30).each { |m, i, o, g| puts "    UNEXPLAINED #{m} #{i.inspect[0, 60]} ours=#{o.inspect[0, 20]} genie=#{g.inspect[0, 30]}" }
      puts "  [#{fuzzer}] --accept refused: #{unexplained.length} diffs match no allowlist entry"
      return 1
    end
    old = load_accepted(path) || {}
    new_keys = rows.to_h { |m, i, *| [[m, i], true] }
    added = new_keys.keys - old.keys
    removed = old.keys - new_keys.keys
    Dir.mkdir(File.dirname(path)) unless Dir.exist?(File.dirname(path))
    File.open(path, 'w') do |f|
      f.puts "# exact-key accepted diffs for #{fuzzer} vs #{TREE} (OracleEnv.finish); #{ACCEPTED_FIELDS.join("\t")}"
      f.puts '# regenerate with --accept ONLY after reviewing the added keys it prints'
      rows.sort.each { |m, i, o, g, fi| f.puts [m, i.dump, o.dump, g.dump, fi].join("\t") }
    end
    puts "  [#{fuzzer}] accepted #{rows.length} diffs -> #{path} (added #{added.length}, removed #{removed.length})"
    added.first(30).each { |m, i| puts "    ADDED   #{m} #{i.inspect[0, 70]}" }
    removed.first(30).each { |m, i| puts "    REMOVED #{m} #{i.inspect[0, 70]}" }
    0
  end
end
