--- Pipe-table rendering: parses GitHub-style Markdown tables and redraws
--- them as aligned, box-drawn tables (┌─┬─┐ │ ├─┼─┤ └─┴─┘) using extmarks.
---
--- Each source row is concealed and replaced by inline virtual text built from
--- the computed column widths, so columns line up regardless of how ragged the
--- source is. Top and bottom borders are added as virtual lines.
local M = {}

local dw = vim.fn.strdisplaywidth

--- Split a table row into trimmed cell strings (outer pipes dropped).
local function split_cells(line)
  local cells = {}
  for cell in line:gmatch("[^|]+") do
    cells[#cells + 1] = vim.trim(cell)
  end
  return cells
end

--- Is this line a table separator row (e.g. `| :--- | ---: |`)?
local function is_separator(line)
  return line:match("^%s*|?[%s:%-|]+|?%s*$") ~= nil and line:find("%-") ~= nil and line:find("|") ~= nil
end

--- Per-column alignment from the separator cells.
local function alignments(sep_line)
  local aligns = {}
  for _, c in ipairs(split_cells(sep_line)) do
    local l, r = c:sub(1, 1) == ":", c:sub(-1) == ":"
    aligns[#aligns + 1] = (l and r) and "center" or (r and "right") or "left"
  end
  return aligns
end

--- Scan the buffer for table regions.
---@param lines string[]
---@param code_set table  rows inside fenced code (excluded)
---@return table[] regions  { header, sep, last, ncols, colw[], aligns[] }
function M.scan(lines, code_set)
  local regions = {}
  local i = 1
  while i < #lines do
    local header, sep = lines[i], lines[i + 1]
    if not code_set[i - 1] and header:find("|") and sep and is_separator(sep) and not header:match("^%s*$") then
      local hcells = split_cells(header)
      local aligns = alignments(sep)
      local ncols = math.max(#hcells, #aligns)
      -- gather body rows
      local last = i + 1 -- separator row index (1-based)
      local j = i + 2
      while j <= #lines and lines[j]:find("|") and not lines[j]:match("^%s*$") and not code_set[j - 1] do
        last = j
        j = j + 1
      end
      -- column widths across header + body
      local colw = {}
      for c = 1, ncols do
        colw[c] = math.max(3, dw(hcells[c] or ""))
      end
      for r = i + 2, last do
        local cells = split_cells(lines[r])
        for c = 1, ncols do
          colw[c] = math.max(colw[c], dw(cells[c] or ""))
        end
      end
      regions[#regions + 1] = {
        header = i - 1, -- 0-based rows for extmarks
        sep = i, -- 0-based
        last = last - 1, -- 0-based
        ncols = ncols,
        colw = colw,
        aligns = aligns,
      }
      i = j
    else
      i = i + 1
    end
  end
  return regions
end

--- Pad `content` to `width` cells per `align`.
local function pad(content, width, align)
  local p = math.max(0, width - dw(content))
  if align == "right" then
    return string.rep(" ", p) .. content
  elseif align == "center" then
    local l = math.floor(p / 2)
    return string.rep(" ", l) .. content .. string.rep(" ", p - l)
  end
  return content .. string.rep(" ", p)
end

--- Build a horizontal border line, e.g. ┌────┬──────┐.
local function border(region, left, mid, right)
  local s = left
  for c = 1, region.ncols do
    s = s .. string.rep("─", region.colw[c] + 2)
    s = s .. (c < region.ncols and mid or right)
  end
  return { { s, "MdRenderTable" } }
end

--- Inline virt_text chunks for a content row.
local function row_chunks(region, cells, is_header)
  local chunks = { { "│", "MdRenderTable" } }
  for c = 1, region.ncols do
    local cell = pad(cells[c] or "", region.colw[c], region.aligns[c] or "left")
    chunks[#chunks + 1] = { " " .. cell .. " ", is_header and "MdRenderTableHead" or "MdRenderTableCell" }
    chunks[#chunks + 1] = { "│", "MdRenderTable" }
  end
  return chunks
end

--- Render one table region. `set` places extmarks; `reveal_row` (0-based) is the
--- cursor line, shown raw.
function M.render(set, region, lines, reveal_row)
  local function draw(row, chunks)
    if row == reveal_row then
      return
    end
    set(row, 0, { end_col = #lines[row + 1], conceal = "" })
    set(row, 0, { virt_text = chunks, virt_text_pos = "inline" })
  end

  -- top border above the header
  set(region.header, 0, { virt_lines = { border(region, "┌", "┬", "┐") }, virt_lines_above = true })
  -- header row
  draw(region.header, row_chunks(region, split_cells(lines[region.header + 1]), true))
  -- separator row -> middle border
  draw(region.sep, border(region, "├", "┼", "┤"))
  -- body rows
  for row = region.sep + 1, region.last do
    draw(row, row_chunks(region, split_cells(lines[row + 1]), false))
  end
  -- bottom border below the last row
  set(region.last, 0, { virt_lines = { border(region, "└", "┴", "┘") } })
end

return M
