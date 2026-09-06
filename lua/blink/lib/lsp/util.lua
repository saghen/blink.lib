--- Helpers for in-process servers. Positions are 0-based rows and byte columns, since the
--- servers negotiate `positionEncoding = 'utf-8'`. Everything else is `vim.lsp.util`.
--- @class blink.lib.lsp.util
local util = {}

--- Loaded buffer for a document, or nil. Never creates a buffer (unlike `vim.uri_to_bufnr`).
--- @param doc lsp.TextDocumentIdentifier | string
--- @return integer?
function util.bufnr(doc)
  local uri = type(doc) == 'table' and doc.uri or doc
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.uri_from_bufnr(bufnr) == uri then return bufnr end
  end
end

--- Position → 0-based row and byte column.
--- @param pos lsp.Position
--- @return integer row, integer col
function util.position(pos) return pos.line, pos.character end

--- `lsp.Range` from 0-based rows and byte columns.
--- @param _bufnr integer
--- @param start_row integer
--- @param start_col integer
--- @param end_row integer
--- @param end_col integer
--- @return lsp.Range
function util.range(_bufnr, start_row, start_col, end_row, end_col)
  return {
    start = { line = start_row, character = start_col },
    ['end'] = { line = end_row, character = end_col },
  }
end

--- `lsp.TextEdit` from a range and text.
--- @param range lsp.Range
--- @param new_text string
--- @return lsp.TextEdit
function util.text_edit(range, new_text) return { range = range, newText = new_text } end

--- `lsp.Location` for a buffer.
--- @param bufnr integer
--- @param range lsp.Range
--- @return lsp.Location
function util.location(bufnr, range) return { uri = vim.uri_from_bufnr(bufnr), range = range } end

--- `lsp.MarkupContent`; `kind` defaults to `markdown`.
--- @param text string | string[]
--- @param kind? 'markdown' | 'plaintext'
--- @return lsp.MarkupContent
function util.markup(text, kind)
  return { kind = kind or 'markdown', value = type(text) == 'table' and table.concat(text, '\n') or text }
end

--- Keyword range around a position per the buffer's `iskeyword`, for `itemDefaults.editRange`.
--- Returns the full range and the prefix range (keyword start to the position).
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return lsp.Range range, lsp.Range prefix
function util.keyword_range(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local before, after = line:sub(1, col), line:sub(col + 1)

  local start_col, end_col = col, col
  vim.api.nvim_buf_call(bufnr, function()
    start_col = vim.fn.match(before, '\\k*$')
    end_col = col + math.max(vim.fn.matchend(after, '^\\k*'), 0)
  end)

  return util.range(bufnr, row, start_col, row, end_col), util.range(bufnr, row, start_col, row, col)
end

--- Minimal `TextEdit[]` turning `old_lines` into `new_lines` (`vim.text.diff` indices).
--- @param old_lines string[]
--- @param new_lines string[]
--- @return lsp.TextEdit[]
function util.edits_from_diff(old_lines, new_lines)
  if #old_lines == 0 then return { util.text_edit(util.range(0, 0, 0, 0, 0), table.concat(new_lines, '\n')) } end

  local old_text = table.concat(old_lines, '\n') .. '\n'
  local new_text = table.concat(new_lines, '\n') .. '\n'
  local hunks = vim.text.diff(old_text, new_text, { result_type = 'indices' })
  --- @cast hunks integer[][]

  local edits = {}
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    local text = table.concat(vim.list_slice(new_lines, start_b, start_b + count_b - 1), '\n')

    if count_a > 0 then
      local first, last = start_a, start_a + count_a - 1
      if count_b > 0 then
        edits[#edits + 1] = util.text_edit(util.range(0, first - 1, 0, last - 1, #old_lines[last]), text)
      elseif last < #old_lines then
        edits[#edits + 1] = util.text_edit(util.range(0, first - 1, 0, last, 0), '')
      elseif first > 1 then
        edits[#edits + 1] =
          util.text_edit(util.range(0, first - 2, #old_lines[first - 1], last - 1, #old_lines[last]), '')
      else
        edits[#edits + 1] = util.text_edit(util.range(0, 0, 0, last - 1, #old_lines[last]), '')
      end
    elseif start_a < #old_lines then
      -- insertion before old line `start_a + 1` (0 = before the first line)
      edits[#edits + 1] = util.text_edit(util.range(0, start_a, 0, start_a, 0), text .. '\n')
    else
      local len = #old_lines[start_a]
      edits[#edits + 1] = util.text_edit(util.range(0, start_a - 1, len, start_a - 1, len), '\n' .. text)
    end
  end
  return edits
end

--- Treesitter node at a position (`vim.treesitter.get_node`), nil without a parser.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return TSNode?
function util.node_at(bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col }, ignore_injections = false })
  if ok then return node end
end

return util
