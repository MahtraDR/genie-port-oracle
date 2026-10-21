# Compatibility sweep: run every real Genie script in the corpus through our engine's
# lexer/compiler and report what loads clean vs. what emits unknown-command warnings
# (the real remaining gaps) or errors. This is "running the scripts through our engine"
# at the load level -- a breadth signal across the whole corpus.
require_relative 'lab_paths'
$LOAD_PATH.unshift(LabPaths.lich_lib)
require 'genie'
include Lich::Genie

CORPORA = LabPaths.corpora! # CORPUS_DIR=label=dir:label=dir...

def loader_for(dir)
  lambda do |name|
    cand = name.include?('.') ? [name] : [name, "#{name}.cmd", "#{name}.inc"]
    cand.each do |c|
      hit = Dir.glob("#{dir}/**/#{c}").first
      return File.read(hit) if hit
    end
    nil
  end
end

unknown_tally = Hash.new(0)
grand = { files: 0, clean: 0, warned: 0, errored: 0 }

CORPORA.each do |label, dir|
  files = Dir.glob("#{dir}/**/*.{cmd,inc}").reject { |f| File.basename(f).end_with?('.js') }
  loader = loader_for(dir)
  clean = warned = errored = 0
  worst = []
  files.each do |path|
    begin
      src = File.read(path)
      prog = Engine.compile(src, include_loader: loader, ignore_warnings: true)
      warns = prog.warnings.reject { |w| w[:content].to_s.strip.empty? }
      if warns.empty?
        clean += 1
      else
        warned += 1
        warns.each do |w|
          tok = w[:content].to_s.strip.split(/\s+/).first.to_s.downcase.sub(/^#/, '#')
          unknown_tally[tok] += 1
        end
        worst << [File.basename(path), warns.length]
      end
    rescue StandardError => e
      errored += 1
      worst << [File.basename(path), "ERR: #{e.class}"]
    end
  end
  grand[:files] += files.length; grand[:clean] += clean; grand[:warned] += warned; grand[:errored] += errored
  pct = files.empty? ? 0 : (100.0 * clean / files.length).round(1)
  puts format('  %-18s %5d files | %5d clean (%.1f%%) | %4d warned | %3d errored',
              label, files.length, clean, pct, warned, errored)
  worst.sort_by { |_, n| n.is_a?(Integer) ? -n : 0 }.first(3).each { |bn, n| puts "        worst: #{bn} (#{n})" }
end

puts '='*78
g = grand
puts format('  TOTAL              %5d files | %5d clean (%.1f%%) | %4d warned | %3d errored',
            g[:files], g[:clean], 100.0 * g[:clean] / g[:files], g[:warned], g[:errored])
puts '='*78
puts '  Unknown/unhandled leading tokens across the corpus (count) -- the real gaps:'
unknown_tally.sort_by { |_, n| -n }.first(25).each { |tok, n| puts format('     %-22s %5d', tok.inspect, n) }
