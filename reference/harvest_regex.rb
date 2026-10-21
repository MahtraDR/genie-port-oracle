# frozen_string_literal: true

# G54 gate: harvest every matchre/waitforre/action/#trigger pattern from the corpus and
# compare compile-ability under .NET (genieoracle, Remix build: `new Regex`) with
#   * raw Ruby Regexp.new (informational: what the engine did before WP2), and
#   * the engine's Lich::Genie::NetRegex.valid? (the gate: must agree with .NET).
# Also reports, for every pattern NetRegex rewrites, the before/after text.
#
# Usage: ruby harvest_regex.rb [--verbose]
# Exit 1 when NetRegex and .NET disagree on any harvested pattern.
#
# Promoted from audits/2026-10-18/evidence/tests-tooling/harvest.rb (WP2).
require 'open3'
require_relative 'lab_paths'
ENGINE = LabPaths.lich_lib
$LOAD_PATH.unshift(ENGINE)
require 'genie/net_regex'

DIRS = LabPaths.corpora!.values.freeze # CORPUS_DIR
DOTNET = LabPaths.dotnet
TFM = ENV.fetch('GENIE_TFM', 'net10.0') # net10.0 (default, the runtime Remix ships on) | net8.0 (legacy)
ORACLE = LabPaths.oracle_dll('remix', TFM)
abort "genieoracle not built: run GENIE=remix GENIE_TFM=#{TFM} #{LabPaths::ROOT}/oracle/build.sh" unless File.exist?(ORACLE)
verbose = ARGV.include?('--verbose')

# Same-file variable expansion (WP3-r2 parity N7: GenieHunter hunt.cmd:309's
# `action ... when (%critters) ...` was skipped as "has a %var", so the one corpus pattern
# NetRegex got wrong was never harvested). Every `var`/`setvariable NAME VALUE` of the file is
# collected; a %NAME (longest defined name wins) is replaced by each of its values,
# recursively (values may hold %vars), at most MAX_EXPANSIONS variants per pattern and 200
# substitution steps (a var set many times, nested, would explode). A pattern
# with a %var the file never defines is still skipped.
MAX_EXPANSIONS = 8
VAR_DEF = /\A(?:var|setvariable)\s+([A-Za-z_][\w.]*)\s+(.+)\z/i

def expand_vars(pattern, defs, out = [], budget = [200])
  return out if out.size >= MAX_EXPANSIONS || (budget[0] -= 1).negative?
  return out << pattern unless pattern.match?(/%[A-Za-z_]/)

  at = pattern.index(/%[A-Za-z_]/)
  word = pattern[(at + 1)..][/\A[\w.]+/]
  name = defs.keys.select { |k| word.start_with?(k) }.max_by(&:length)
  return out unless name

  head = pattern[0...at]
  tail = pattern[(at + 1 + name.length)..]
  defs[name].each { |value| expand_vars("#{head}#{value}#{tail}", defs, out, budget) }
  out.uniq!
  out
end

pats = Hash.new { |h, k| h[k] = [] }
expanded = 0
DIRS.each do |d|
  Dir.glob("#{d}/**/*.{cmd,inc,CMD,Cmd}").each do |f|
    lines = File.readlines(f, encoding: 'bom|utf-8').map { |l| l.scrub.strip }
    defs = Hash.new { |h, k| h[k] = [] }
    lines.each { |l| defs[Regexp.last_match(1)] |= [Regexp.last_match(2).strip] if l =~ VAR_DEF }
    lines.each.with_index(1) do |l, n|
      found = []
      if l =~ /\A(?:matchre\s+\S+|waitforre)\s+(.+)\z/i then found << Regexp.last_match(1)
      elsif l =~ /\Aaction\b.*?\bwhen\s+(.+)\z/i then found << Regexp.last_match(1)
      elsif l =~ /#trigger\s+\{([^{}]*)\}/i then found << Regexp.last_match(1)
      end
      # Eval's matchre()/replacere() (WP3-r2 engineering NB4: NetRegex since v0.15.2).
      l.scan(/\b(?:matchre|replacere)\s*\(\s*"[^"]*"\s*,\s*"([^"]*)"/i) { |m| found << m.first }
      found.each do |p|
        p = p.strip.sub(%r{\A/(.*)/i?\z}, '\1')
        next if p.empty? || p.include?('"')

        variants = p.match?(/%[A-Za-z_]/) ? expand_vars(p, defs) : [p]
        expanded += 1 if variants.any? && variants != [p]
        variants.each do |v|
          next if v.empty? || v.include?('"') || v.match?(/%[A-Za-z_]/)

          pats[v] << "#{File.basename(f)}:#{n}"
        end
      end
    end
  end
end
list = pats.keys
input = list.map { |p| %(eval\tmatchre("", "#{p}")) }.join("\n")
out, err, st = Open3.capture3(DOTNET, ORACLE, '--stdin', stdin_data: input)
abort "oracle failed: #{err}" unless st.success?
net = out.split("\n")
abort "oracle returned #{net.size} lines for #{list.size} patterns" unless net.size == list.size
if (dump = ENV.fetch('ORACLE_DUMP', nil)) && !dump.empty? # same format as OracleEnv.dump
  File.open(dump, 'a') { |f| input.split("\n").each_with_index { |l, i| f.puts "#{l.dump}\t=> #{net[i].to_s.dump}" } }
end

raw_diff = 0
gate_diff = 0
rewritten = 0
$stderr.reopen(File::NULL) # Onigmo prints warnings for some corpus patterns; not relevant here
list.each_with_index do |p, i|
  net_ok = !net[i].to_s.start_with?('ERR')
  raw_ok = begin
    Regexp.new(p)
    true
  rescue RegexpError
    false
  end
  ours_ok = Lich::Genie::NetRegex.valid?(p)
  raw_diff += 1 if raw_ok != net_ok
  if ours_ok != net_ok
    gate_diff += 1
    verdict = "netregex=#{ours_ok ? 'ok' : 'ERR'} dotnet=#{net_ok ? 'ok' : net[i]}"
    puts "GATE DIFF #{verdict} pat=#{p[0, 100]} e.g. #{pats[p].first}"
  end
  next unless ours_ok

  t = Lich::Genie::NetRegex.translate(p)
  next if t == p

  rewritten += 1
  puts "REWRITE #{pats[p].first}: #{p[0, 100]}\n     -> #{t[0, 100]}" if verbose
end
puts "unique patterns: #{list.size} (#{expanded} source patterns expanded through same-file vars)"
puts "raw Ruby vs .NET compile-ability diffs: #{raw_diff}"
puts "NetRegex vs .NET compile-ability diffs: #{gate_diff}"
puts "patterns NetRegex rewrites: #{rewritten}#{verbose ? '' : ' (--verbose lists them)'}"
exit(gate_diff.zero? ? 0 : 1)
