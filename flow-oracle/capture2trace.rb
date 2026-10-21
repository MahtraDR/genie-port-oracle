# frozen_string_literal: true

# Convert a genie_capture.lic log (reference/genie_capture.lic: "<epoch>\tIN|OUT|SNAP\t<payload>")
# into a genieflow trace, so a captured live DR session can be replayed through Genie4's REAL
# engine (and, via diff_driver.rb, through ours).
#
#   ruby capture2trace.rb <capture.log> [--snap-vars] > session.trace
#
# * IN payloads are raw server strings (XML intact). They are re-split into socket rows exactly
#   like Connection.ParseData (Connection.cs:578): a row ends at \r or \n; a trailing partial row
#   is carried into the next record. Each IN record ends with FLUSH (= one socket receive ->
#   EventDataRecieveEnd -> Script.SetBufferEnd).
# * Time between records becomes WAIT <ms> (virtual clock).
# * OUT records become comments (# OUT ...) -- they are what the capturing client sent.
# * --snap-vars: the first SNAP's vars become VAR lines (reserved game vars only; user globals
#   are not in SNAP -- pass the user's variables.cfg to genieflow with --vars instead).

require 'json'
require_relative '../reference/capture_log' # CaptureLog.parse_log / decode_inspect (no engine needed)

path = ARGV.find { |a| !a.start_with?('--') } or abort 'usage: ruby capture2trace.rb <capture.log> [--snap-vars]'
snap_vars = ARGV.include?('--snap-vars')

records = CaptureLog.parse_log(path)
out = []
last_epoch = nil
partial = +''
snapped = false
records.each do |r|
  if last_epoch
    gap = ((r.epoch - last_epoch) * 1000).round
    out << "WAIT #{gap}" if gap >= 10
  end
  last_epoch = r.epoch
  case r.kind
  when :snap
    next unless snap_vars && !snapped

    snapped = true
    (r.payload['vars'] || {}).each { |k, v| out << "VAR #{k} #{v}" unless v.to_s.include?("\n") }
  when :out
    out << "# OUT #{r.payload.inspect}"
  when :in
    buf = partial + r.payload
    rows = buf.split(/\r\n|\r|\n/, -1)
    partial = rows.pop.to_s # text after the last newline (maybe empty)
    rows.each { |row| out << "IN #{row}" }
    out << 'FLUSH'
  end
end
out << "IN #{partial}" unless partial.empty?
puts out
