--- Extmark-based markdown decoration engine.
---
--- Decorates the visible region of a markdown buffer using extmarks: conceals
--- syntax markers, overlays Nerd-Font/ASCII glyphs, and paints highlights for
--- headings, emphasis, code, lists, tasks, quotes, rules, links and tables.
--- No treesitter dependency — line-oriented scanning keeps it self-contained.
local config = require("mdrender.config")

local M = {}

local ns = vim.api.nvim_create_namespace("mdrender")
--- buf -> augroup id of its attached autocommands
local attached = {}
--- coalesce multiple events fired in the same tick into one render
local pending = {}

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

--- Is the editor currently in a mode where we should render?
local function mode_active()
  local m = vim.api.nvim_get_mode().mode:sub(1, 1)
  for _, allowed in ipairs(config.opts.render_modes) do
    if m == allowed then
      return true
    end
  end
  return false
end

--- Find a window in the current tabpage displaying `buf`, preferring the
--- current window. Returns nil if the buffer is not visible.
local function window_for(buf)
  if vim.api.nvim_get_current_buf() == buf then
    return vim.api.nvim_get_current_win()
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

----------------------------------------------------------------------
-- line-level decorations
----------------------------------------------------------------------

--- Build a closure that places extmarks on `buf`, swallowing range errors.
local function make_setter(buf)
  return function(row, col, opts)
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
  end
end

--- Scan the whole buffer for fenced code blocks.
---@return table regions  list of { s = start_row, e = end_row, lang = string }
---@return table code_set  set of row -> true for every row inside a block
local function scan_fences(lines)
  local regions, code_set = {}, {}
  local open = nil
  for i, line in ipairs(lines) do
    local row = i - 1
    local fence = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if fence then
      if not open then
        local lang = line:match("^%s*[`~]+%s*([%w_%.%+%-]*)") or ""
        open = { s = row, lang = lang }
      else
        regions[#regions + 1] = { s = open.s, e = row, lang = open.lang }
        open = nil
      end
    end
  end
  if open then
    regions[#regions + 1] = { s = open.s, e = #lines - 1, lang = open.lang }
  end
  for _, r in ipairs(regions) do
    for row = r.s, r.e do
      code_set[row] = true
    end
  end
  return regions, code_set
end

--- Inline span decorations within a single (non-code) line. Skipped entirely on
--- the revealed cursor line so the raw source is shown for editing.
local function decorate_inline(set, row, line, reveal)
  if reveal then
    return
  end
  local occ = {} -- byte positions (1-indexed) already consumed
  local function free(s, e)
    for i = s, e do
      if occ[i] then
        return false
      end
    end
    return true
  end
  local function take(s, e)
    for i = s, e do
      occ[i] = true
    end
  end

  -- inline code `code` (first, so emphasis never fires inside it)
  do
    local init = 1
    while true do
      local s, e = line:find("`[^`]+`", init)
      if not s then
        break
      end
      init = e + 1
      if free(s, e) then
        set(row, s - 1, { end_col = s, conceal = "" })
        set(row, e - 1, { end_col = e, conceal = "" })
        set(row, s, { end_col = e - 1, hl_group = "MdRenderCodeInline" })
        take(s, e)
      end
    end
  end

  -- links [text](url) and images ![alt](url)
  do
    local opts = config.opts.link
    local init = 1
    while true do
      local ms, me, txt = line:find("%[([^%]]-)%]%([^%)]-%)", init)
      if not ms then
        break
      end
      init = me + 1
      if free(ms, me) and opts.enabled then
        local is_image = ms > 1 and line:sub(ms - 1, ms - 1) == "!"
        local conceal_start = is_image and ms - 1 or ms
        local txt_end = ms + #txt -- 1-indexed last char of text
        set(row, conceal_start - 1, { end_col = ms, conceal = "" })
        if config.gpu then
          local icon = is_image and opts.image_icon or opts.icon
          set(row, conceal_start - 1, {
            virt_text = { { icon, "MdRenderLinkIcon" } },
            virt_text_pos = "inline",
          })
        end
        set(row, ms, { end_col = txt_end, hl_group = "MdRenderLink" })
        set(row, txt_end, { end_col = me, conceal = "" })
        take(is_image and ms - 1 or ms, me)
      end
    end
  end

  -- emphasis: bold, strikethrough, then italic
  local function emphasis(pat, len, hl, boundary)
    local init = 1
    while true do
      local s, e = line:find(pat, init)
      if not s then
        break
      end
      init = e + 1
      if free(s, e) then
        if boundary then
          local before = s > 1 and line:sub(s - 1, s - 1) or " "
          local after = e < #line and line:sub(e + 1, e + 1) or " "
          if before:match("[%w]") or after:match("[%w]") then
            goto continue
          end
        end
        set(row, s - 1, { end_col = s - 1 + len, conceal = "" })
        set(row, e - len, { end_col = e, conceal = "" })
        set(row, s - 1 + len, { end_col = e - len, hl_group = hl })
        take(s, e)
      end
      ::continue::
    end
  end

  emphasis("%*%*%*[^%*]+%*%*%*", 3, "MdRenderBoldItalic", false)
  emphasis("%*%*[^%*]+%*%*", 2, "MdRenderBold", false)
  emphasis("__[^_]+__", 2, "MdRenderBold", true)
  emphasis("~~[^~]+~~", 2, "MdRenderStrike", false)
  emphasis("%*[^%*]+%*", 1, "MdRenderItalic", false)
  emphasis("_[^_]+_", 1, "MdRenderItalic", true)
end

--- Decorate one logical line. `reveal` is true on the cursor line (anti-conceal)
--- so we skip conceal/overlay marks but still keep background highlights.
local function decorate_line(set, row, line, ctx)
  local o = config.opts
  local nf = config.gpu

  -- fenced code block --------------------------------------------------------
  if ctx.code_set[row] then
    if o.code.enabled and o.code.style == "full" then
      set(row, 0, { line_hl_group = "MdRenderCode" })
    end
    if not ctx.reveal then
      if ctx.fence_open[row] ~= nil then
        local lang = ctx.fence_open[row]
        set(row, 0, { end_col = #line, conceal = "" })
        if o.code.language then
          local label = (nf and o.code.lang_icon or "") .. (lang ~= "" and lang or "code")
          set(row, 0, {
            virt_text = { { " " .. label .. " ", "MdRenderCodeLang" } },
            virt_text_pos = "inline",
          })
        end
      elseif ctx.fence_close[row] then
        set(row, 0, { end_col = #line, conceal = "" })
      end
    end
    return
  end

  -- ATX heading --------------------------------------------------------------
  if o.heading.enabled then
    local hashes, sp = line:match("^(#+)(%s+)")
    if hashes and #hashes <= 6 then
      local level = #hashes
      set(row, 0, { line_hl_group = "MdRenderH" .. level })
      if not ctx.reveal then
        local icons = nf and o.heading.icons or o.heading.ascii
        set(row, 0, { end_col = #hashes + #sp, conceal = "" })
        set(row, 0, {
          virt_text = { { icons[level], "MdRenderH" .. level } },
          virt_text_pos = "inline",
        })
      end
      decorate_inline(set, row, line, ctx.reveal)
      return
    end
  end

  -- horizontal rule ----------------------------------------------------------
  if o.dash.enabled then
    local body = line:gsub("%s", "")
    if #body >= 3 and (body:match("^%-+$") or body:match("^%*+$") or body:match("^_+$")) then
      if not ctx.reveal then
        set(row, 0, { end_col = #line, conceal = "" })
        local width = ctx.width
        set(row, 0, {
          virt_text = { { string.rep(o.dash.icon, width), "MdRenderRule" } },
          virt_text_pos = "overlay",
        })
      end
      return
    end
  end

  -- blockquote ---------------------------------------------------------------
  if o.quote.enabled then
    local prefix = line:match("^(%s*>[>%s]*)")
    if prefix then
      if not ctx.reveal then
        -- conceal every '>' marker, render a colored bar in its place
        for idx = 1, #prefix do
          if prefix:sub(idx, idx) == ">" then
            set(row, idx - 1, { end_col = idx, conceal = "" })
          end
        end
        local bar = nf and o.quote.icon or o.quote.ascii
        local lead = #(line:match("^(%s*)") or "")
        set(row, lead, {
          virt_text = { { bar, "MdRenderQuote" } },
          virt_text_pos = "inline",
        })
      end
      decorate_inline(set, row, line, ctx.reveal)
      return
    end
  end

  -- task list item -----------------------------------------------------------
  if o.checkbox.enabled then
    local indent, state = line:match("^(%s*)[%-%*%+]%s+%[([ xX])%]")
    if indent then
      local s, e = line:find("^%s*[%-%*%+]%s+%[[ xX]%]")
      local done = state == "x" or state == "X"
      if not ctx.reveal then
        set(row, #indent, { end_col = e, conceal = "" })
        local box = done and o.checkbox.checked or o.checkbox.unchecked
        set(row, #indent, {
          virt_text = { { nf and box.icon or box.ascii, done and "MdRenderCheckDone" or "MdRenderCheck" } },
          virt_text_pos = "inline",
        })
      end
      if done then
        set(row, e, { end_col = #line, hl_group = "MdRenderCheckDone" })
      else
        decorate_inline(set, row, line, ctx.reveal)
      end
      return
    end
  end

  -- unordered list bullet ----------------------------------------------------
  if o.bullet.enabled then
    local indent = line:match("^(%s*)[%-%*%+]%s")
    if indent then
      if not ctx.reveal then
        local icons = nf and o.bullet.icons or o.bullet.ascii
        local depth = math.floor(#indent / 2) % #icons + 1
        set(row, #indent, { end_col = #indent + 1, conceal = "" })
        set(row, #indent, {
          virt_text = { { icons[depth], "MdRenderBullet" } },
          virt_text_pos = "inline",
        })
      end
      decorate_inline(set, row, line, ctx.reveal)
      return
    end
  end

  -- ordered list number ------------------------------------------------------
  if o.bullet.enabled then
    local indent, num = line:match("^(%s*)(%d+[%.%)])%s")
    if indent then
      set(row, #indent, { end_col = #indent + #num, hl_group = "MdRenderOrdered" })
      decorate_inline(set, row, line, ctx.reveal)
      return
    end
  end

  -- table row ----------------------------------------------------------------
  if o.table.enabled and line:find("|") then
    local trimmed = line:gsub("%s", "")
    local is_sep = trimmed:match("^|?[:%-|]+|?$") and trimmed:find("%-")
    if is_sep then
      if not ctx.reveal then
        set(row, 0, { end_col = #line, conceal = "" })
        local cells = {}
        for ch in line:gmatch(".") do
          if ch == "|" then
            cells[#cells + 1] = "┼"
          elseif ch == "-" or ch == ":" then
            cells[#cells + 1] = "─"
          elseif ch == " " then
            cells[#cells + 1] = " "
          end
        end
        set(row, 0, {
          virt_text = { { table.concat(cells), "MdRenderTable" } },
          virt_text_pos = "overlay",
        })
      end
      return
    else
      -- color the pipes; still apply inline styling inside cells
      local idx = line:find("|", 1, true)
      while idx do
        set(row, idx - 1, { end_col = idx, hl_group = "MdRenderTable" })
        idx = line:find("|", idx + 1, true)
      end
      decorate_inline(set, row, line, ctx.reveal)
      return
    end
  end

  -- plain paragraph line -----------------------------------------------------
  decorate_inline(set, row, line, ctx.reveal)
end

----------------------------------------------------------------------
-- top-level render
----------------------------------------------------------------------

--- Clear all mdrender extmarks from a buffer.
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

--- Render (or re-render) the visible region of `buf`.
function M.render(buf)
  if not attached[buf] or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  M.clear(buf)
  if not config.opts.enabled or not mode_active() then
    return -- show raw source
  end

  local win = window_for(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local regions, code_set = scan_fences(lines)

  local fence_open, fence_close = {}, {}
  for _, r in ipairs(regions) do
    fence_open[r.s] = r.lang
    fence_close[r.e] = true
  end

  local top, bot, width, cursor_row = 0, #lines - 1, 120, -1
  if win then
    width = vim.api.nvim_win_get_width(win)
    -- When the whole buffer fits in the window, render all of it. Otherwise
    -- limit work to the visible range (re-triggered on WinScrolled).
    if #lines > vim.api.nvim_win_get_height(win) then
      vim.api.nvim_win_call(win, function()
        top = vim.fn.line("w0") - 1
        bot = vim.fn.line("w$") - 1
      end)
    end
    if vim.api.nvim_get_current_win() == win and config.opts.anti_conceal then
      cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
    end
  end

  local set = make_setter(buf)
  for row = top, bot do
    local line = lines[row + 1]
    if line then
      decorate_line(set, row, line, {
        code_set = code_set,
        fence_open = fence_open,
        fence_close = fence_close,
        reveal = row == cursor_row,
        width = width,
      })
    end
  end

  -- inline images (experimental, GPU only) -----------------------------------
  if config.opts.images.enabled then
    local ok, image = pcall(require, "mdrender.image")
    if ok then
      image.render_visible(buf, lines, top, bot)
    end
  end
end

--- Coalesced render: at most one render per event-loop tick per buffer.
local function schedule(buf)
  if pending[buf] then
    return
  end
  pending[buf] = true
  vim.schedule(function()
    pending[buf] = nil
    M.render(buf)
  end)
end

----------------------------------------------------------------------
-- attach / detach lifecycle
----------------------------------------------------------------------

--- Apply window-local options needed for conceal to take effect.
local function apply_win_options(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_option_value("conceallevel", config.opts.conceal_level, { win = win })
      -- empty concealcursor => raw text on the cursor line (works with anti_conceal)
      vim.api.nvim_set_option_value("concealcursor", config.opts.anti_conceal and "" or "nvic", { win = win })
    end
  end
end

--- Attach decorations to a buffer.
function M.attach(buf)
  if attached[buf] then
    return
  end
  local group = vim.api.nvim_create_augroup("MdRender_" .. buf, { clear = true })
  attached[buf] = group

  apply_win_options(buf)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CursorMoved", "ModeChanged" }, {
    group = group,
    buffer = buf,
    callback = function()
      schedule(buf)
    end,
  })
  -- WinScrolled / WinResized are not buffer-local; filter inside the callback.
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "BufWinEnter" }, {
    group = group,
    callback = function()
      if window_for(buf) then
        apply_win_options(buf)
        schedule(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      M.detach(buf)
    end,
  })

  schedule(buf)
end

--- Detach decorations from a buffer.
function M.detach(buf)
  if not attached[buf] then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, attached[buf])
  attached[buf] = nil
  M.clear(buf)
  if config.opts.images.enabled then
    pcall(function()
      require("mdrender.image").clear(buf)
    end)
  end
end

--- Is `buf` currently decorated?
function M.is_attached(buf)
  return attached[buf] ~= nil
end

return M
