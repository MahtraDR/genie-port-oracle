# frozen_string_literal: true

# Reader for genie_capture.lic logs ("<epoch>\tIN|OUT|SNAP\t<payload>", IN/OUT payloads written
# with String#inspect, SNAP payloads JSON). No engine dependency. Used by
# flow-oracle/capture2trace.rb (capture -> genieflow trace, replayed through the real Remix engine
# and, via diff_driver.rb, through ours).
#
# Extracted 2026-10-20 (WPZ lab cleanup) verbatim from the retired reference/replay_fixture.rb
# (its own scheduler/engine model is superseded by capture2trace.rb + flow-oracle/diff_driver.rb;
# see README "Lab tooling").
require 'json'

module CaptureLog
  Record = Struct.new(:epoch, :kind, :payload)

  # --- log parsing ---------------------------------------------------------

  # Decode a Ruby String#inspect literal WITHOUT eval. Handles the escapes inspect
  # emits for game text: \\ \" \n \r \t \e \s \0 \a \b \f \v, \xHH, \uHHHH, \uHHHHHH
  # ({}), octal \nnn, and \#{ / \#@ / \#$ (inspect escapes interpolation sigils).
  def self.decode_inspect(text)
    body = text.strip
    body = body[1..-2] if body.start_with?('"') && body.end_with?('"')
    out = +''
    i = 0
    simple = { '\\' => '\\', '"' => '"', 'n' => "\n", 'r' => "\r", 't' => "\t",
               'e' => "\e", 's' => ' ', 'a' => "\a", 'b' => "\b", 'f' => "\f",
               'v' => "\v", '0' => "\0", '#' => '#' }
    while i < body.length
      ch = body[i]
      if ch != '\\'
        out << ch
        i += 1
        next
      end
      nxt = body[i + 1]
      if nxt == 'x'
        out << [body[i + 2, 2].to_i(16)].pack('C')
        i += 4
      elsif nxt == 'u' && body[i + 2] == '{'
        close = body.index('}', i + 2)
        out << body[(i + 3)...close].split.map { |h| h.to_i(16) }.pack('U*')
        i = close + 1
      elsif nxt == 'u'
        out << [body[i + 2, 4].to_i(16)].pack('U')
        i += 6
      elsif nxt =~ /[0-7]/
        oct = body[(i + 1)..].match(/\A[0-7]{1,3}/)[0]
        out << [oct.to_i(8)].pack('C')
        i += 1 + oct.length
      elsif simple.key?(nxt)
        out << simple[nxt]
        i += 2
      else
        out << nxt.to_s
        i += 2
      end
    end
    out
  end

  def self.parse_log(path)
    records = []
    File.foreach(path) do |raw|
      line = raw.chomp
      next if line.empty?

      epoch_s, kind, payload = line.split("\t", 3)
      epoch = epoch_s.to_f
      case kind
      when 'IN'   then records << Record.new(epoch, :in, decode_inspect(payload))
      when 'OUT'  then records << Record.new(epoch, :out, decode_inspect(payload))
      when 'SNAP' then records << Record.new(epoch, :snap, JSON.parse(payload))
      end
    end
    records
  end
end
