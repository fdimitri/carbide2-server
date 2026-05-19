# FsDocument — simple in-memory line buffer used by DirectoryEntry#calc_current.
# Supports the same change_type operations as FileChange.  Not persisted.
class FsDocument
  def initialize
    @lines = []
  end

  def set_contents(data)
    @lines = if data.is_a?(Array)
               data.map { |l| l.to_s }
             else
               data.to_s.split("\n", -1)
             end
  end

  def get_contents
    @lines.join("\n")
  end

  # insertDataSingleLine — insert text at (startLine, startChar)
  def do_insert_data_single_line(_client, msg)
    p    = unwrap(msg, 'insertDataSingleLine')
    line = p['startLine'].to_i
    ch   = p['startChar'].to_i
    data = p['data'].to_s.gsub("\r", '')
    @lines[line] ||= ''
    @lines[line] = @lines[line].dup.insert([ch, @lines[line].length].min, data)
  end

  # deleteDataSingleLine — remove text from startChar to endChar on startLine
  def do_delete_data_single_line(_client, msg)
    p    = unwrap(msg, 'deleteDataSingleLine')
    line = p['startLine'].to_i
    ch   = p['startChar'].to_i
    len  = p['endChar'].to_i - ch
    return unless @lines[line] && len > 0
    @lines[line] = @lines[line].dup
    @lines[line][ch, len] = ''
  end

  # insertDataMultiLine — data may be a newline-containing String or Array of lines.
  # Inserts at (startLine, startChar).
  def do_insert_data_multi_line(_client, msg)
    p          = unwrap(msg, 'insertDataMultiLine')
    start_line = p['startLine'].to_i
    start_char = p['startChar'].to_i
    raw        = p['data']

    data = case raw
           when Array  then raw.map(&:to_s)
           when String then raw.split("\n", -1)
           else return
           end
    return unless data.any?

    @lines[start_line] ||= ''
    tail = @lines[start_line][start_char..] || ''
    @lines[start_line] = @lines[start_line][0...start_char].to_s + data[0].to_s

    if data.length > 1
      extra = data[1..-2].map(&:to_s)
      extra << (data.last.to_s + tail)
      @lines.insert(start_line + 1, *extra)
    else
      @lines[start_line] += tail
    end
  end

  # deleteDataMultiLine — remove from (startLine, startChar) to (endLine, endChar)
  def do_delete_data_multi_line(_client, msg)
    p          = unwrap(msg, 'deleteDataMultiLine')
    start_line = p['startLine'].to_i
    start_char = p['startChar'].to_i
    end_line   = p['endLine'].to_i
    end_char   = p['endChar'].to_i
    return if start_line >= @lines.length

    start_part = (@lines[start_line] || '')[0...start_char].to_s
    end_part   = (@lines[end_line]   || '')[end_char..].to_s
    @lines.slice!(start_line, end_line - start_line + 1)
    @lines.insert(start_line, start_part + end_part)
  end

  private

  def unwrap(msg, key)
    h = msg.is_a?(Hash) ? msg : JSON.parse(msg.to_s)
    h.key?(key) ? h[key] : h
  end
end
