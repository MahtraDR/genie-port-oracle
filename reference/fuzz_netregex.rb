# frozen_string_literal: true

# NetRegex (script patterns: matchre / waitforre / action / #trigger) vs .NET `new Regex(p,
# Multiline [| IgnoreCase])` -- genieoracle `rxmatch` mode, GENIE=remix (default).
#
# Compares, for random patterns built from lookbehinds (fixed / variable-length / negative /
# capturing, at the start, mid-pattern, inside groups and quantified groups), inline options
# `(?i)` `(?-i)` `(?s)` at every placement (mid-branch, nested groups, across `|`), scoped
# options, alternations, classes, quantifiers and a few invalid fragments:
#   * VALIDITY: .NET "ERR:*" <=> NetRegex.valid? false. An Unsupported pattern (NetRegex
#     registers it, never fires, warns once) counts as valid.
#   * MATCH (both valid, NetRegex not Unsupported): every group's value, "" for unmatched.
#   * LOST MATCH (WP3-r2 engineering NB2): NetRegex Unsupported but .NET matched. A diff
#     unless the reason is a construct NetRegex deliberately does not translate (KNOWN_SOUND)
#     or a "no fixed distance" reason that an INDEPENDENT check confirms (the path from the
#     start of the lookbehind's own alternatives, read as one Onigmo lookbehind body, must be
#     rejected as variable-length; a quantified enclosing group must really be there). The
#     r1 bug class (hunt.cmd:309: Unsupported for a lookbehind whose distance IS fixed) shows
#     up here.
#     Groups after a capturing lookbehind are compared but the lookbehind's own capture is a
#     recorded divergence (NetRegex placeholder ""), so such patterns compare group 0 only.
#
#   bundle exec ruby fuzz_netregex.rb [N] [seed] [--verbose]
#   NETREGEX_LIB=<copy>/lib ruby fuzz_netregex.rb ...   (a mutant copy: sensitivity check)
# Exit 1 on any diff. Unsupported counts are reported (they are not diffs), and so are
# onigmo_fault rows: Onigmo's MatchData#to_a raising "negative string size" on some nested
# empty loops (raw Regexp.new of the same text raises too; recorded in todo.md G54 rest).
require 'open3'
require_relative 'lab_paths'
$LOAD_PATH.unshift(ENV.fetch('NETREGEX_LIB', LabPaths.lich_lib)) # a mutant copy for sensitivity checks
require 'genie/net_regex'

TREE = ENV.fetch('GENIE', 'remix')
DOTNET = LabPaths.dotnet
TFM = ENV.fetch('GENIE_TFM', 'net10.0') # net10.0 (default, the runtime Remix ships on) | net8.0 (legacy)
ORACLE = LabPaths.oracle_dll(TREE, TFM)
abort "genieoracle not built: run GENIE=#{TREE} GENIE_TFM=#{TFM} #{LabPaths::ROOT}/oracle/build.sh" unless File.exist?(ORACLE)

args = ARGV.reject { |a| a.start_with?('--') }
N = (args[0] || 3000).to_i
srand((args[1] || 4242).to_i)
VERBOSE = ARGV.include?('--verbose')

LOOKBEHINDS = [
  '(?<=a)', '(?<!a)', '(?<=ab|c)', '(?<=a+)', '(?<!a+)', '(?<=\\w+ )', '(?<!arisen \\S+ )',
  '(?<=a*)', '(?<!b?)', '(?<=(a|bb))', '(?<=x\\S+)', '(?<!(?i)A+)', '(?<=a{2,3})', '(?<=^\\w+)',
  '(?<!\\d+)', '(?<=[ab]+)', '(?<=a|b+)'
].freeze
# (?x) is left out: pattern-whitespace mode is not modelled by the translator (0 corpus, todo G54).
OPTIONS = ['(?i)', '(?-i)', '(?s)', '(?i-s)', '(?m)', '(?-)', '(?i-)'].freeze
ATOMS = [
  'a', 'b', 'A', 'B', 'c', ' ', 'x', '.', '\\w', '\\S', '\\s', '\\d', '[ab]', '[^a]', 'zombie', 'big'
].freeze
# Zero-width atoms are never quantified: .NET and Onigmo differ on empty loops (`^+?`, `\b{2}`;
# .NET even throws ArgumentOutOfRange/Overflow for some), 0 corpus, outside this fuzz.
ANCHORS = ['^', '$', '\\b'].freeze
# Mode 'fixed' (half the cases) keeps every non-lookbehind part fixed-width so variable-length
# lookbehinds are reachable by the Emulated path instead of falling to Unsupported.
QUANTS_ANY = ['', '', '', '+', '*', '?', '{2}', '+?', '{1,2}'].freeze
QUANTS_FIXED = ['', '', '', '{2}', '{2}?'].freeze
$fixed = false
BAD = ['a++', '(?)', '(', ')', '\\q', '*a', '(?<=a', 'a{2}*'].freeze

def atom
  case rand(10)
  when 0, 1 then LOOKBEHINDS.sample + (rand(8).zero? ? ['*', '?', '+', '{2}'].sample : '')
  when 2 then OPTIONS.sample
  when 3 then ANCHORS.sample
  else "#{ATOMS.sample}#{($fixed ? QUANTS_FIXED : QUANTS_ANY).sample}"
  end
end

def seq(depth)
  Array.new(rand(1..4)) do
    if depth < 2 && rand(6).zero?
      inner = Array.new(rand(1..3)) { seq(depth + 1) }.join('|')
      open = ['(', '(?:', '(?i:', '(?-i:'].sample
      "#{open}#{inner})#{($fixed ? ['', '', '{2}'] : ['', '', '+', '?', '*', '{2}']).sample}"
    else
      atom
    end
  end.join
end

def pattern
  $fixed = rand(2).zero?
  p = Array.new(rand(1..3)) { seq(0) }.join('|')
  p += BAD.sample if rand(40).zero?
  p
end

SUBJECTS = [
  'a', 'ab', 'aab', 'xaab', 'AB', 'Ab', 'ba', 'c', 'C', 'abc', 'big zombie', 'arisen big zombie',
  'An arisen big zombie x', 'a big zombie', 'zombie mauler', 'aaab b', 'A a', 'x Y z', '12 ab', '',
  'bb aa', 'aA bB'
].freeze

cases = Array.new(N) { [pattern, SUBJECTS.sample, rand(4).zero? ? 'i' : ''] }.uniq
lines = cases.map { |pat, subj, fl| "rxmatch\t#{fl}\x1f#{pat}\x1f#{subj}" }
out, err, st = Open3.capture3(DOTNET, ORACLE, '--stdin', stdin_data: lines.join("\n"))
abort "oracle failed: #{err}" unless st.success?
net = out.split("\n", -1)
net.pop if net.last == ''
abort "oracle returned #{net.size} lines for #{cases.size}" unless net.size == cases.size
if (dump = ENV.fetch('ORACLE_DUMP', nil)) && !dump.empty? # same format as OracleEnv.dump
  File.open(dump, 'a') { |f| lines.each_with_index { |l, i| f.puts "#{l.dump}\t=> #{net[i].to_s.dump}" } }
end

$stderr.reopen(File::NULL) unless ENV["FUZZ_STDERR"] # Onigmo warnings
# Unsupported reasons that name a construct NetRegex deliberately leaves out (each .NET-valid,
# each with a spec in net_regex_spec.rb): no independent check needed.
KNOWN_SOUND = [
  'the explicit-capture option n', 'a balancing group', 'a numbered group name', 'a conditional on an expression',
  'a back-reference to a capture inside a rewritten lookbehind',
  'a variable-length lookbehind containing an atomic group', 'a variable-length lookbehind containing a back-reference',
  'a variable-length lookbehind containing a named group', 'a variable-length lookbehind containing a conditional',
  'a variable-length lookbehind whose body Onigmo cannot compile on its own'
].freeze

# Independent of NetRegex.fixed_offset: the text on the path to +target+ (each enclosing
# level from the start of its current alternative; group openers dropped, captures made
# non-capturing, other lookbehinds dropped) must be something Onigmo refuses as a lookbehind
# body (= variable width) for "after a variable-width part" to be true.
def path_to(text, target)
  # per open level: [opener index (nil at the top), start of the current alternative]
  levels = [[nil, 0]]
  j = 0
  while j < target
    case text[j]
    when '\\' then j += 1
    when '[' then j = Lich::Genie::NetRegex.class_end(text, j) - 1
    when '('
      head = text[j..][/\A\((?:\?(?:[:=!>]|<[=!]|<\w+>|'\w+'|[imsx]*-?[imsx]*:))?/].to_s
      levels << [j, j + head.length]
      j += head.length - 1
    when ')' then levels.pop
    when '|' then levels[-1] = [levels[-1][0], j + 1]
    end
    j += 1
  end
  levels.each_with_index.map do |(_opener, alt_start), k|
    stop = k + 1 < levels.size ? levels[k + 1][0] : target
    text[alt_start...stop]
  end.join
end

# Width-neutral cleanup so that Onigmo's lookbehind check only answers "fixed width?":
# lookarounds (zero width; Onigmo refuses lookaheads inside a lookbehind) are dropped with
# any quantifier, atomic/named/capturing groups become (?: (same width).
def width_only(body)
  out = +''
  j = 0
  while j < body.length
    if body[j] == '\\'
      out << body[j, 2]
      j += 2
    elsif body[j] == '['
      stop = Lich::Genie::NetRegex.class_end(body, j)
      out << body[j...stop]
      j = stop
    elsif body[j] == '(' && body[j..].match?(/\A\(\?(?:[=!]|<[=!])/)
      close = Lich::Genie::NetRegex.group_close(body, j) || body.length
      j = close + 1
      j += body[j..][/\A(?:[*+?]|\{\d+(?:,\d*)?\})\??/].to_s.length
    elsif body[j] == '('
      head = body[j..][/\A\((?:\?(?:>|<\w+>|'\w+'|:))|\A\((?!\?)/].to_s # atomic/named/plain -> (?:
      out << (head.empty? ? '(' : '(?:')
      j += [head.length, 1].max
    else
      out << body[j]
      j += 1
    end
  end
  out
end

def variable_width_confirmed?(text, target)
  body = path_to(text, target)
  return true if body.match?(/\\(?:[1-9]|k<)/) # a back-reference has no fixed width

  Regexp.new("(?<=x#{width_only(body)})") # the x: Onigmo treats a body that is one (?:a|bb) group as top-level alternatives
  false
rescue RegexpError => e
  e.message.include?('look-behind')
end

def quantified_confirmed?(text, target)
  stack = []
  j = 0
  while j < target
    case text[j]
    when '\\' then j += 1
    when '(' then stack << j
    when ')' then stack.pop
    end
    j += 1
  end
  stack.any? do |open|
    close = Lich::Genie::NetRegex.group_close(text, open)
    close && text[close + 1].to_s.match?(/[*+?{]/) && !text[(close + 1)..].start_with?('{1}')
  end
end

def unsupported_sound?(pat, _flags, reason)
  return true if KNOWN_SOUND.include?(reason)

  nr = Lich::Genie::NetRegex
  notes = nr::Notes.new(*nr::Notes.members.map { |m| m == :groups ? nr.group_inventory(pat) : [] }) # older copies: 2 members
  text = Lich::Genie::NetRegex.scan(pat, notes)
  check = case reason
          when /after a variable-width part/ then method(:variable_width_confirmed?)
          when /inside a quantified group/ then method(:quantified_confirmed?)
          else return false
          end
  notes.lookbehinds.any? { |lb| check.call(text, lb.start) }
end

diffs = []
unsupported = Hash.new(0)
emulated = 0
cases.each_with_index do |(pat, subj, fl), i|
  genie = net[i]
  genie_ok = !genie.start_with?('ERR')
  compiled = begin
    Lich::Genie::NetRegex.compile(pat, ignore_case: fl == 'i')
  rescue StandardError
    nil
  end
  ours_ok = !compiled.nil?
  if ours_ok != genie_ok
    diffs << [:validity, pat, subj, fl, "ours=#{ours_ok ? 'ok' : 'ERR'}", "net=#{genie}"]
    next
  end
  next unless ours_ok

  if compiled.is_a?(Lich::Genie::NetRegex::Unsupported)
    unsupported[compiled.reason] += 1
    if genie.split("\x1f", 2).first.to_i.positive? && !unsupported_sound?(pat, fl, compiled.reason)
      diffs << [:unsupported_lost, pat, subj, fl, "ours=Unsupported (#{compiled.reason})", "net=#{genie.tr("\x1f", '|')}"]
    end
    next
  end
  emulated += 1 if compiled.is_a?(Lich::Genie::NetRegex::Emulated)
  ours = begin
    m = compiled.match(subj)
    m ? m.to_a.map(&:to_s) : []
  rescue StandardError => e # an Onigmo fault surfaces as a diff, not a crash
    ["RAISED #{e.class}: #{e.message}"]
  end
  theirs = genie.split("\x1f", -1)
  count = theirs.shift.to_i
  theirs = theirs.first(count)
  if pat.match?(/\(\?<[=!][^)]*\(/) # capturing lookbehind: placeholder "" (recorded) -> group 0 only
    ours = ours.first(1)
    theirs = theirs.first(1)
  end
  next if ours == theirs

  # Onigmo's own MatchData fault on nested empty loops (raw Ruby raises the same; todo G54 rest)
  kind = ours.first.to_s.start_with?('RAISED ArgumentError: negative string size') ? :onigmo_fault : :match
  diffs << [kind, pat, subj, fl, ours.inspect, theirs.inspect]
end
faults = diffs.select { |d| d.first == :onigmo_fault }

puts "fuzz_netregex (#{TREE}): #{cases.size} cases, #{diffs.size} diffs, #{emulated} via Emulated, " \
     "#{unsupported.values.sum} Unsupported"
unsupported.each { |reason, n| puts "  unsupported #{n}: #{reason}" }
diffs.group_by(&:first).each do |kind, list|
  puts "#{kind}: #{list.size}"
  list.first(VERBOSE ? list.size : 15).each { |d| puts "  #{d[1..].map(&:to_s).join(' | ')}" }
end
exit(diffs.size == faults.size ? 0 : 1)
