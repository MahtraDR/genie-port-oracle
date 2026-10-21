# frozen_string_literal: true

# Property / invariant tester for the Genie engine's PURE helpers -- no oracle needed.
# Each invariant is a structural property that must hold for MANY random inputs. This
# complements the differential fuzzers (fuzz_numeric/fuzz_parseargs) and the example
# specs: it hunts for bugs that only surface on inputs nobody wrote an example for.
#
#   ruby reference/property_invariants.rb [N] [seed]
#
# N     = iterations per invariant (default 20000)
# seed  = srand seed for reproducibility (default 1337)
#
# Exit status is nonzero if ANY invariant is violated. Each violation prints the exact
# failing input, expected vs actual, and a short diagnosis pointer.
require_relative 'lab_paths'
$LOAD_PATH.unshift(LabPaths.lich_lib)
require 'genie'

N    = (ARGV[0] || 20_000).to_i
SEED = (ARGV[1] || 1337).to_i
srand(SEED)

NM  = Lich::Genie::Numeric
TX  = Lich::Genie::Text
VB  = Lich::Genie::VbConversions
INF = [0x221E].pack('U')

# ---------------------------------------------------------------------------
# small harness
# ---------------------------------------------------------------------------
Result = Struct.new(:name, :statement, :samples, :violations)

def run(name, statement)
  viol = []
  samples = yield(viol)
  Result.new(name, statement, samples, viol)
end

def bits(f) = [f].pack('D')            # bit-exact double comparison key
def rand_sign = rand(2).zero? ? 1 : -1

# a random finite double: half from raw 64-bit patterns (covers subnormals + huge),
# half from structured magnitudes clustered around the fixed<->scientific boundaries.
BOUNDARY_MAG = [
  1e-5, 1e-4, 1e-3, 1e15, 1e16, 1e17, 9.999999999999998e15, 1.0000000000000002e16,
  Float::MIN, Float::MAX, 5e-324, 2.2250738585072014e-308
].freeze

def rand_double
  f =
    if rand(2).zero?
      [rand(2**64)].pack('Q').unpack1('D')
    else
      case rand(6)
      when 0 then rand_sign * BOUNDARY_MAG.sample * (rand(1..9))
      when 1 then rand_sign * rand * 10.0**rand(-30..30)
      when 2 then (rand_sign * rand(0..2_000_000_000)).to_f
      when 3 then rand_sign * rand(0..999_999) / 10.0**rand(0..6)
      when 4 then rand_sign * BOUNDARY_MAG.sample
      else rand_sign * 10.0**rand(-320..308) * (1 + rand)
      end
    end
  # The invariant is over FINITE doubles only: format_double emits the Unicode
  # infinity glyph / "NaN", which .NET's own double.Parse does not accept back.
  # Some structured generators (e.g. Float::MAX * 9) overflow -- retry those.
  (f.nan? || f.infinite?) ? rand_double : f
end

# random string over an alphabet that stresses the tokenizers/splitter
SPLIT_ALPHA = ['a', 'b', 'c', '1', ' ', '  ', '{', '}', '"', '\\', ';', ',', '|', 'x', '_'].freeze
def rand_split_string
  Array.new(rand(0..14)) { SPLIT_ALPHA.sample }.join
end

SAFE_TOK = ('a'..'z').to_a + ('0'..'9').to_a
def rand_safe_token = Array.new(rand(1..6)) { SAFE_TOK.sample }.join

# format_double structural shape: fixed (no leading zeros bar "0.x"/"0"/"-0") or
# scientific ("d" or "d.ddd" mantissa, 'E', explicit sign, >=2 exponent digits).
FIXED_RE = /\A-?(?:\d+|\d+\.\d+)\z/
SCI_RE   = /\A-?\d(?:\.\d+)?E[+-]\d{2,}\z/
LEADZERO = /\A-?0\d/ # illegal leading zero in the integer part

# ---------------------------------------------------------------------------
# INVARIANT 1: format_double -> string_to_double is a bit-exact round trip on
# every FINITE double. (NaN/Inf excluded: .NET's own double.Parse rejects the
# Unicode infinity glyph and NaN != NaN, so a value round trip cannot apply.)
# ---------------------------------------------------------------------------
r1 = run('fmt_s2d_roundtrip',
         'for finite d: string_to_double(format_double(d)) reproduces d bit-for-bit') do |viol|
  n = 0
  N.times do
    d = rand_double
    n += 1
    s = NM.format_double(d)
    back = NM.string_to_double(s)
    next if bits(back) == bits(d)

    viol << { input: d, repr: s, expected: d, actual: back,
              note: 'reparse of format_double output did not recover the exact double' } if viol.size < 12
  end
  n
end

# ---------------------------------------------------------------------------
# INVARIANT 2: format_double output is STRUCTURALLY well formed for finite d
# (fixed or scientific shape, no lowercase 'e', no bogus leading zeros).
# ---------------------------------------------------------------------------
r2 = run('fmt_shape',
         'for finite d: format_double(d) matches the .NET fixed/scientific shape') do |viol|
  n = 0
  N.times do
    d = rand_double
    n += 1
    s = NM.format_double(d)
    ok = (s.match?(FIXED_RE) || s.match?(SCI_RE)) && !s.match?(LEADZERO)
    next if ok

    viol << { input: d, repr: s, expected: 'FIXED_RE|SCI_RE, no leading zero', actual: s,
              note: 'malformed format_double layout' } if viol.size < 12
  end
  n
end

# ---------------------------------------------------------------------------
# INVARIANT 3: format_double is idempotent THROUGH a parse round trip, i.e. it
# is a canonical form: format_double(string_to_double(format_double(d))) ==
# format_double(d). (Follows from 1, but tests the string layer directly and
# would catch a parse/format asymmetry even if bit-compare somehow masked it.)
# ---------------------------------------------------------------------------
r3 = run('fmt_canonical',
         'for finite d: format_double(string_to_double(format_double(d))) == format_double(d)') do |viol|
  n = 0
  N.times do
    d = rand_double
    n += 1
    s1 = NM.format_double(d)
    s2 = NM.format_double(NM.string_to_double(s1))
    next if s1 == s2

    viol << { input: d, repr: s1, expected: s1, actual: s2,
              note: 'format_double is not stable across a parse' } if viol.size < 12
  end
  n
end

# ---------------------------------------------------------------------------
# INVARIANT 4: remix_safe_split reconstruction (Text.remix_safe_split, the literal port of
# Remix Utility.SafeSplit, Utility.cs:782-844 R; it replaced the old Text.safe_split in WP4).
# Splitting on a single-char separator and rejoining with that separator reconstructs the
# input byte-for-byte, because the split only ever CONSUMES the separators it splits on and
# keeps every other character verbatim (escapes, quotes, braces, empty segments fold into the
# next piece). The one separator it can lose is a FINAL one that closed a piece (`a;` -> [a]),
# so the invariant is `rejoined == s || rejoined + sep == s`. No piece is ever empty.
# ---------------------------------------------------------------------------
SEPS = [';', ',', '|', '/', ':', '#', '{', '"', '\\', 'z'].freeze
r4 = run('safe_split_rejoin',
         'remix_safe_split(s, sep).join(sep) == s (or + sep == s for a consumed final sep); no empty piece') do |viol|
  n = 0
  N.times do
    s = rand_split_string
    sep = SEPS.sample
    n += 1
    pieces = TX.remix_safe_split(s, sep)
    rebuilt = pieces.join(sep)
    next if (rebuilt == s || (s.end_with?(sep) && rebuilt + sep == s)) && pieces.none?(&:empty?)

    viol << { input: [s, sep], repr: pieces.inspect, expected: s, actual: rebuilt,
              note: 'split/rejoin did not reconstruct the input (or produced an empty piece)' } if viol.size < 12
  end
  n
end

# ---------------------------------------------------------------------------
# INVARIANT 5: parse_args plain round trip. For tokens drawn from a "safe"
# alphabet (no space/quote/brace/backslash/underscore) joined by single spaces,
# parse_args recovers exactly those tokens. (Genie strips wrapping quotes/braces
# and keeps backslashes, so this is the round trip that DOES hold; the general
# join is intentionally lossy.)
# ---------------------------------------------------------------------------
r5 = run('parseargs_plain_roundtrip',
         'parse_args(safe_tokens.join(" ")) == safe_tokens') do |viol|
  n = 0
  N.times do
    toks = Array.new(rand(1..6)) { rand_safe_token }
    n += 1
    got = TX.parse_args(toks.join(' '))
    next if got == toks

    viol << { input: toks.join(' '), repr: got.inspect, expected: toks, actual: got,
              note: 'plain space-joined tokens did not round trip' } if viol.size < 12
  end
  n
end

# ---------------------------------------------------------------------------
# INVARIANT 6: double -> Int32 invariants (VbConversions.double_to_integer, the strict port of
# VB Conversions.ToInteger(double) = checked((int)Math.Round(x)); it replaced the lenient
# Numeric.to_integer in WP8). Banker's rounding is within 0.5 of the input and is a fixpoint on
# its own output; an integer-valued double in Int32 range round trips; a double outside the
# Int32 range (after rounding) raises Lich::Genie::Error (OverflowException), never wraps.
# ---------------------------------------------------------------------------
INT32_MAX = (2**31) - 1
r6 = run('to_integer_props',
         'double_to_integer is |.|<=0.5 of input, idempotent, identity on integral Int32 doubles, raises outside Int32') do |viol|
  n = 0
  N.times do
    x = rand_sign * rand(0..INT32_MAX) / (10.0**rand(0..6))
    n += 1
    r = VB.double_to_integer(x)
    fixpoint = VB.double_to_integer(r.to_f)
    intval = rand_sign * rand(0..INT32_MAX)
    idn = VB.double_to_integer(intval.to_f)
    big = rand_sign * (INT32_MAX + 1 + rand(0..2**52))
    raised = begin
      VB.double_to_integer(big.to_f)
      false
    rescue Lich::Genie::Error
      true
    end
    bad = []
    bad << 'distance>0.5' if (r - x).abs > 0.5
    bad << 'not integer' unless r.is_a?(Integer)
    bad << 'not idempotent' if fixpoint != r
    bad << 'not identity on integral' if idn != intval
    bad << 'no overflow outside Int32' unless raised || big == -(INT32_MAX + 1)
    next if bad.empty?

    viol << { input: [x, intval, big], repr: [r, fixpoint, idn, raised].inspect, expected: 'props hold',
              actual: bad.join(','), note: 'double_to_integer property failed' } if viol.size < 12
  end
  n
end

# ---------------------------------------------------------------------------
# INVARIANT 7: substitution no-op on sigil-free text. If a line contains none
# of %, $, @ then expand returns it unchanged.
# ---------------------------------------------------------------------------
NOSIGIL = ('a'..'z').to_a + ('0'..'9').to_a + [' ', '(', ')', '.', '|', '_', '\\']
r7 = run('subst_nosigil_noop',
         'expand(text) == text when text has no %, $, or @') do |viol|
  vars = Lich::Genie::Variables.new
  vars.local_set('foo', 'X')
  vars.global_set('bar', 'Y')
  clock = -> { Time.new(2026, 8, 24, 14, 5, 9) }
  sub = Lich::Genie::Substitution.new(variables: vars,
                                      specials: Lich::Genie::Specials.new(clock: clock, timer: -> { '42' }, directories: {}))
  n = 0
  N.times do
    s = Array.new(rand(0..16)) { NOSIGIL.sample }.join
    n += 1
    out = sub.expand(s, args: %w[all one two])
    next if out == s

    viol << { input: s, repr: out.inspect, expected: s, actual: out,
              note: 'expand mutated sigil-free text' } if viol.size < 12
  end
  n
end

# ---------------------------------------------------------------------------
# INVARIANT 8: substitution idempotence for the %local / @special forms with
# sigil-free values AND no '$' and no backslash in the input.
#
# The ORIGINAL statement -- "expand is idempotent whenever all values are
# sigil-free" -- is FALSE under Genie parity, by design (see report):
#   * expand UN-ESCAPES: "\$" -> "$", "\%" -> "%". A second expand then treats
#     the now-live sigil as a real reference, so escapes are single-application.
#   * $-args are resolved in a pass that runs BEFORE the %/$ pass, and numbered
#     args are ALWAYS replaced. A literal "$3" that only appears AFTER the first
#     expand (formed by un-escaping or by the %/$ pass deleting text between a
#     surviving '$' and a digit) is eaten on the next expand.
# Both are correct single-pass Genie behavior, not bugs. The property that DOES
# hold is idempotence once the two escape/ordering hazards are removed: restrict
# the input alphabet to exclude '$' and '\' (keep %local + @special).
# ---------------------------------------------------------------------------
SUB_ALPHA = ['a', 'b', 'c', 'o', 'g', 'l', '1', '2', '%', '@', ' ', '(', ')', '.', '|', '_'].freeze
r8 = run('subst_idempotent',
         'expand(expand(s)) == expand(s) for %local/@special input (no $, no backslash), sigil-free values') do |viol|
  clock = -> { Time.new(2026, 8, 24, 14, 5, 9) }
  n = 0
  N.times do
    vars = Lich::Genie::Variables.new
    # random sigil-free var names/values (names alnum; values may contain | for arrays)
    rand(0..4).times do
      name = Array.new(rand(1..4)) { SAFE_TOK.sample }.join
      val = Array.new(rand(0..6)) { (SAFE_TOK + ['|']).sample }.join
      rand(2).zero? ? vars.local_set(name, val) : vars.global_set(name, val)
    end
    sub = Lich::Genie::Substitution.new(variables: vars,
                                        specials: Lich::Genie::Specials.new(clock: clock, timer: -> { '7' }, directories: {}))
    args = Array.new(rand(0..4)) { Array.new(rand(0..4)) { SAFE_TOK.sample }.join }
    s = Array.new(rand(0..18)) { SUB_ALPHA.sample }.join
    n += 1
    once = sub.expand(s, args: args)
    twice = sub.expand(once, args: args)
    next if once == twice

    viol << { input: [s, args], repr: once.inspect, expected: once, actual: twice,
              note: 'expand is not idempotent even though all values are sigil-free' } if viol.size < 12
  end
  n
end

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
results = [r1, r2, r3, r4, r5, r6, r7, r8]
bar = '=' * 78
puts "\n#{bar}"
puts "  Genie engine PROPERTY / INVARIANT check   (N=#{N} per invariant, seed #{SEED})"
puts bar
results.each do |r|
  status = r.violations.empty? ? 'HOLDS   ' : "VIOLATED (#{r.violations.size}+ shown)"
  puts format('  [%s] %-26s  n=%d', status, r.name, r.samples)
  puts format('       %s', r.statement)
end
puts bar

any = false
results.each do |r|
  next if r.violations.empty?

  any = true
  puts "\n  VIOLATIONS for #{r.name}:"
  r.violations.each do |v|
    puts "    input:    #{v[:input].inspect}"
    puts "    repr:     #{v[:repr]}"
    puts "    expected: #{v[:expected].inspect}"
    puts "    actual:   #{v[:actual].inspect}"
    puts "    note:     #{v[:note]}"
    puts '    ----'
  end
end
puts(any ? "\n  RESULT: at least one invariant VIOLATED" : "\n  RESULT: all invariants HOLD")
puts bar
exit(any ? 1 : 0)
