# Remix-vs-upstream golden diff: compares tests/expected-remix/*.jsonl with tests/expected-upstream/*.jsonl
# (setup line ignored). Output: test|same, test|differs|upstream-only: ... || remix-only: ..., or test|remix-only.
#   ruby golden_diff.rb
require 'json'
dir = File.expand_path('tests', __dir__)
names = (Dir["#{dir}/expected-remix/*.jsonl"] + Dir["#{dir}/expected-upstream/*.jsonl"]).map { |f| File.basename(f, '.jsonl') }.uniq.sort
KEEP = %w[send echo error print cmdecho var trigger-fire inputbox script-finish genie-crash halted queue]
def load(p) = File.exist?(p) ? File.readlines(p).drop(1).map { |l| JSON.parse(l) } : nil
def fmt(e) = "#{e['t'].to_i}ms #{e['ev']} #{(e['text'] || e['name'].to_s + '=' + e['value'].to_s rescue '')[0, 70].inspect}"
names.each do |n|
  r = load("#{dir}/expected-remix/#{n}.jsonl"); u = load("#{dir}/expected-upstream/#{n}.jsonl")
  if r.nil? || u.nil? then puts "#{n}|#{r ? 'remix-only' : 'upstream-only'}"; next end
  if r == u then puts "#{n}|same"; next end
  rk = r.select { |e| KEEP.include?(e['ev']) }.map { |e| fmt(e) }
  uk = u.select { |e| KEEP.include?(e['ev']) }.map { |e| fmt(e) }
  only_u = uk - rk; only_r = rk - uk
  puts "#{n}|differs|upstream-only: #{only_u.first(4).join(' ; ')}#{only_u.size > 4 ? " (+#{only_u.size - 4})" : ''} || remix-only: #{only_r.first(4).join(' ; ')}#{only_r.size > 4 ? " (+#{only_r.size - 4})" : ''}"
end
