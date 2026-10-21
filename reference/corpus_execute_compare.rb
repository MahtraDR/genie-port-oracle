# frozen_string_literal: true

# Compare two corpus_execute_sweep.rb logs (BEFORE AFTER .log.jsonl): outcome changes, echo
# TEXT changes (echo_sha; the first differing lines from echo_text), send changes (send_sha
# and count). Text changes at an unchanged count are reported too (WP4-r1 engineering NB8).
#
# Run: ruby corpus_execute_compare.rb before.log.jsonl after.log.jsonl [max_lines_per_script]
require 'json'
require_relative 'lab_paths'

# Key each row by `<corpus label>/<path inside that corpus>` when CORPUS_DIR names the corpus
# roots (so two sweeps of copies at different paths compare), else by the full path.
ROOTS = LabPaths.corpora

def row_key(row)
  root = ROOTS[row['corpus']]
  root && row['path'].start_with?("#{root}/") ? "#{row['corpus']}/#{row['path'][(root.length + 1)..]}" : row['path']
end

def load_log(path)
  File.readlines(path).to_h do |line|
    row = JSON.parse(line)
    [row_key(row), row]
  end
end

before = load_log(ARGV.fetch(0))
after = load_log(ARGV.fetch(1))
max_lines = (ARGV[2] || 6).to_i
abort 'logs lack echo_sha: re-run both sweeps with the current corpus_execute_sweep.rb' unless before.values.first&.key?('echo_sha')

outcome = []
echo = []
window = []
send = []
(before.keys | after.keys).sort.each do |key|
  b = before[key]
  a = after[key]
  if b.nil? || a.nil?
    outcome << "  #{key}: #{b ? b['outcome'] : 'absent'} -> #{a ? a['outcome'] : 'absent'}"
    next
  end
  outcome << "  #{key}: #{b['outcome']} -> #{a['outcome']}" if b['outcome'] != a['outcome']
  echo << [key, b, a] if b['echo_sha'] != a['echo_sha']
  window << [key, b, a] if b['window_echo_sha'] != a['window_echo_sha']
  send << "  #{key}: #{b['sends']} -> #{a['sends']}#{' (same count, other text)' if b['sends'] == a['sends']} (#{a['outcome']})" if b['send_sha'] != a['send_sha']
end

puts "scripts: before #{before.size} after #{after.size}"
puts "outcome changes: #{outcome.size}", outcome
def text_changes(title, rows, field, max_lines)
  puts "#{title}: #{rows.size}"
  rows.each do |key, b, a|
    bt = b[field] || []
    at = a[field] || []
    removed = bt - at
    added = at - bt
    puts "  #{key}: #{bt.size} -> #{at.size} lines (logged)"
    removed.first(max_lines).each { |l| puts "      - #{l.inspect}" }
    added.first(max_lines).each { |l| puts "      + #{l.inspect}" }
    puts '      (same lines, other order/count)' if removed.empty? && added.empty?
  end
end

text_changes('echo text changes', echo, 'echo_text', max_lines)
text_changes('window echo (#echo >window) text changes', window, 'window_echo_text', max_lines)
puts "send changes: #{send.size}", send
puts "total sends before #{before.values.sum { |r| r['sends'].to_i }} after #{after.values.sum { |r| r['sends'].to_i }}"
