-- Headless sanity checks. Run with:
--   nvim --clean --headless --cmd "set rtp+=$PWD" -l test/headless_check.lua
local function eq(a, b, msg)
  if a ~= b then
    error(string.format("FAIL %s: expected %s, got %s", msg, vim.inspect(b), vim.inspect(a)), 2)
  end
end
local function ok(cond, msg)
  if not cond then
    error("FAIL " .. msg, 2)
  end
end

local md = require("mdrender")
local config = require("mdrender.config")
local ns = vim.api.nvim_create_namespace("mdrender") -- same name -> same id

-- Force a deterministic, non-GPU (ASCII) setup so the test is host-independent.
md.setup({ require_gpu = false })
config.gpu = false

local lines = {
  "# Title",
  "",
  "Para **bold** *it* `code` ~~no~~ [link](http://x) ![img](./a.png)",
  "- bullet",
  "- [ ] todo",
  "- [x] done",
  "> quote",
  "---",
  "```lua",
  "print(1)",
  "```",
  "| a | b |",
  "| - | - |",
  "| 1 | 2 |",
}

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

-- Put it in a window so the visible-range path runs.
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- park on blank line

local render = require("mdrender.render")
render.attach(buf)
vim.wait(200, function()
  return false
end)
render.render(buf)

local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
ok(#marks > 15, "expected many extmarks, got " .. #marks)

-- Heading line should carry a line highlight + concealed '# '.
local function marks_on(row)
  local out = {}
  for _, m in ipairs(marks) do
    if m[2] == row then
      out[#out + 1] = m[4]
    end
  end
  return out
end
local has_line_hl, has_conceal = false, false
for _, d in ipairs(marks_on(0)) do
  if d.line_hl_group == "MdRenderH1" then
    has_line_hl = true
  end
  if d.conceal ~= nil then
    has_conceal = true
  end
end
ok(has_line_hl, "heading line_hl_group present")
ok(has_conceal, "heading conceal present")

-- ASCII fallback: bullet glyph should be one of the ascii bullets.
local function virt_texts(row)
  local out = {}
  for _, d in ipairs(marks_on(row)) do
    if d.virt_text then
      out[#out + 1] = d.virt_text[1][1]
    end
  end
  return out
end
local bullet_glyphs = virt_texts(3)
ok(#bullet_glyphs > 0, "bullet has a virt_text glyph")
local g = bullet_glyphs[1]
ok(g == "*" or g == "-" or g == "+" or g == "·", "ascii bullet used, got " .. tostring(g))

-- Toggle off clears marks; toggle on restores them.
md.disable(buf)
eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0, "disable clears marks")
md.enable(buf)
render.render(buf)
ok(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0, "enable restores marks")

print("ALL HEADLESS CHECKS PASSED (" .. #marks .. " marks)")
