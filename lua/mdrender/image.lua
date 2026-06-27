--- Experimental inline image rendering via the kitty graphics protocol.
---
--- Uses the Unicode-placeholder variant of the protocol: the image is
--- transmitted once as a *virtual placement*, then displayed by emitting
--- placeholder cells (U+10EEEE) whose row/column is encoded with combining
--- diacritics and whose foreground color carries the image id. The cells are
--- injected as extmark `virt_lines` below the image's markdown link, so they
--- scroll naturally with the buffer.
---
--- Requires a GPU terminal speaking the kitty protocol (kitty/ghostty/wezterm).
--- Works inside tmux when allow-passthrough=all (the shared term module wraps the
--- escapes). Non-PNG images are converted with ImageMagick (`magick`/`convert`)
--- when available.
local config = require("mdrender.config")
local gpu = require("mdrender.gpu")
local term = require("mdrender.term")

local M = {}

local ns = vim.api.nvim_create_namespace("mdrender_image")
local next_id = 1
local transmitted = {} -- path -> { id, cols, rows }

-- Kitty "row/column" diacritics (subset of the official table; supports up to
-- ~140 cells per dimension, plenty for inline previews).
-- stylua: ignore
local DIACRITICS = {
  0x0305,0x030D,0x030E,0x0310,0x0312,0x033D,0x033E,0x033F,0x0346,0x034A,0x034B,
  0x034C,0x0350,0x0351,0x0352,0x0357,0x035B,0x0363,0x0364,0x0365,0x0366,0x0367,
  0x0368,0x0369,0x036A,0x036B,0x036C,0x036D,0x036E,0x036F,0x0483,0x0484,0x0485,
  0x0486,0x0487,0x0592,0x0593,0x0594,0x0595,0x0597,0x0598,0x0599,0x059C,0x059D,
  0x059E,0x059F,0x05A0,0x05A1,0x05A8,0x05A9,0x05AB,0x05AC,0x05AF,0x05C4,0x0610,
  0x0611,0x0612,0x0613,0x0614,0x0615,0x0616,0x0617,0x0657,0x0658,0x0659,0x065A,
  0x065B,0x065D,0x065E,0x06D6,0x06D7,0x06D8,0x06D9,0x06DA,0x06DB,0x06DC,0x06DF,
  0x06E0,0x06E1,0x06E2,0x06E4,0x06E7,0x06E8,0x06EB,0x06EC,0x0730,0x0732,0x0733,
  0x0735,0x0736,0x073A,0x073D,0x073F,0x0740,0x0741,0x0743,0x0745,0x0747,0x0749,
  0x074A,0x07EB,0x07EC,0x07ED,0x07EE,0x07EF,0x07F0,0x07F1,0x07F3,0x0816,0x0817,
  0x0818,0x0819,0x081B,0x081C,0x081D,0x081E,0x081F,0x0820,0x0821,0x0822,0x0823,
  0x0825,0x0826,0x0827,0x0829,0x082A,0x082B,0x082C,0x082D,0x0859,0x085A,0x085B,
  0x08E3,0x08E4,0x08E5,0x08E6,0x08E7,0x08E8,0x08E9,0x08EA,0x08EB,0x08EC,
}
local PLACEHOLDER = 0x10EEEE

--- Minimal UTF-8 encoder (LuaJIT has no utf8 library).
local function utf8c(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
end

--- Read intrinsic pixel size of a PNG from its IHDR chunk.
local function png_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local header = f:read(24)
  f:close()
  if not header or header:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil
  end
  local function be32(s)
    local a, b, c, d = s:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return be32(header:sub(17, 20)), be32(header:sub(21, 24))
end

--- Ensure we have a PNG path for `path` (convert via ImageMagick if needed).
local function ensure_png(path)
  if path:lower():match("%.png$") then
    return path
  end
  local exe = vim.fn.executable("magick") == 1 and "magick" or (vim.fn.executable("convert") == 1 and "convert" or nil)
  if not exe then
    return nil
  end
  local out = vim.fn.tempname() .. ".png"
  vim.fn.system({ exe, path, out })
  if vim.v.shell_error == 0 and vim.fn.filereadable(out) == 1 then
    return out
  end
  return nil
end

--- Transmit `path` as a virtual placement of size cols x rows. Returns the id.
--- Delegates to the shared term module (direct `t=d` transport + tmux passthrough
--- wrapping), the same path the graphical preview uses — so inline images work
--- through tmux and there is only one terminal-output implementation to maintain.
local function transmit(path, cols, rows)
  if transmitted[path] then
    return transmitted[path].id
  end
  local id = next_id
  next_id = next_id + 1
  term.transmit_virtual(id, path, cols, rows)
  transmitted[path] = { id = id, cols = cols, rows = rows }
  return id
end

--- Highlight group whose fg encodes a 24-bit image id (kitty reads fg as id).
local function id_hl(id)
  local name = "MdRenderImg" .. id
  vim.api.nvim_set_hl(0, name, { fg = string.format("#%06x", id % 0x1000000) })
  return name
end

--- Build the placeholder virt_lines for an image of `cols` x `rows` cells.
local function placeholder_lines(id, cols, rows)
  local hl = id_hl(id)
  local ph = utf8c(PLACEHOLDER)
  local lines = {}
  for r = 1, rows do
    local row_dia = utf8c(DIACRITICS[r] or DIACRITICS[#DIACRITICS])
    local cells = {}
    for c = 1, cols do
      local col_dia = utf8c(DIACRITICS[c] or DIACRITICS[#DIACRITICS])
      cells[c] = ph .. row_dia .. col_dia
    end
    lines[r] = { { table.concat(cells), hl } }
  end
  return lines
end

--- Compute cell dimensions for an image, preserving aspect ratio.
local function cell_size(path)
  local w, h = png_size(path)
  if not w or not h then
    return nil
  end
  local cw, ch = config.opts.images.cell_pixels[1], config.opts.images.cell_pixels[2]
  local cols = math.min(config.opts.images.max_width, math.floor(w / cw))
  cols = math.max(cols, 1)
  local rows = math.max(1, math.floor((h / w) * cols * cw / ch))
  return cols, rows
end

--- Render a single image below buffer row `row`.
function M.render_one(buf, row, src)
  local ok = gpu.graphics_available(config.term)
  if not ok then
    return false
  end
  local path = vim.fn.fnamemodify(vim.fn.expand(src), ":p")
  if vim.fn.filereadable(path) ~= 1 then
    return false
  end
  local png = ensure_png(path)
  if not png then
    return false
  end
  local cols, rows = cell_size(png)
  if not cols then
    return false
  end
  local id = transmit(png, cols, rows)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
    virt_lines = placeholder_lines(id, cols, rows),
  })
  return true
end

--- Scan the visible region for image links and render each one.
function M.render_visible(buf, lines, top, bot)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not select(1, gpu.graphics_available(config.term)) then
    return
  end
  for row = top, bot do
    local line = lines[row + 1]
    if line then
      local src = line:match("!%[[^%]]*%]%(([^%)]+)%)")
      if src and not src:match("^https?://") then
        M.render_one(buf, row, src)
      end
    end
  end
end

--- Clear all image placements from a buffer.
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  -- delete every transmitted image from the terminal
  term.delete_all()
  transmitted = {}
end

return M
