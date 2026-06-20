--- Graphical "Obsidian-style" Markdown preview.
---
--- Renders the current buffer to a styled PNG with headless Chrome (HTML + an
--- Obsidian-like CSS theme, marked + highlight.js running client-side), then
--- displays that image in a split window using the kitty graphics protocol.
--- The image is cropped to the preview window and scrolls to follow the source
--- window. Escape sequences are written straight to the controlling tty, the
--- same technique nvim-shader-art uses.
---
--- Requires a kitty-graphics terminal (kitty / Ghostty / WezTerm) and is
--- disabled inside tmux/screen unless graphics passthrough is configured.
local config = require("mdrender.config")
local gpu = require("mdrender.gpu")
local kgp = require("mdrender.kgp")

local M = {}

--- Live preview state, or nil when closed.
---@type table|nil
local state = nil

----------------------------------------------------------------------
-- assets
----------------------------------------------------------------------

local assets = nil
local function load_assets()
  if assets then
    return assets
  end
  local tpl = vim.api.nvim_get_runtime_file("assets/template.html", false)[1]
  if not tpl then
    return nil
  end
  local dir = vim.fn.fnamemodify(tpl, ":h")
  local function read(name)
    local f = io.open(dir .. "/" .. name, "r")
    if not f then
      return ""
    end
    local s = f:read("*a")
    f:close()
    return s
  end
  assets = {
    template = read("template.html"),
    css = read("preview.css"),
    hlcss = read("highlight-github-dark.css"),
    marked = read("marked.min.js"),
    hljs = read("highlight.min.js"),
  }
  return assets
end

--- Locate a Chrome/Chromium binary.
local function find_chrome()
  if config.opts.preview.chrome then
    return config.opts.preview.chrome
  end
  local candidates = {
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "brave-browser",
  }
  for _, c in ipairs(candidates) do
    if c:find("/") then
      if vim.fn.executable(c) == 1 or vim.fn.filereadable(c) == 1 then
        return c
      end
    elseif vim.fn.executable(c) == 1 then
      return c
    end
  end
  return nil
end

----------------------------------------------------------------------
-- rendering: markdown buffer -> PNG (async, via Chrome)
----------------------------------------------------------------------

--- Build the self-contained preview HTML for a buffer and write it to `html_path`.
local function build_html(buf, html_path)
  local a = load_assets()
  if not a then
    return false
  end
  local md = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local name = vim.api.nvim_buf_get_name(buf)
  local base = "file://" .. (name ~= "" and vim.fn.fnamemodify(name, ":h") or vim.fn.getcwd()) .. "/"
  local html = a.template
    :gsub("{{BASE}}", function() return base end)
    :gsub("{{CSS}}", function() return a.css end)
    :gsub("{{HLCSS}}", function() return a.hlcss end)
    :gsub("{{MARKED}}", function() return a.marked end)
    :gsub("{{HLJS}}", function() return a.hljs end)
    -- escape "</" so markdown containing </script> can't break out of the tag
    :gsub("{{CONTENT_JSON}}", function() return (vim.json.encode(md):gsub("</", "<\\/")) end)
  local f = io.open(html_path, "w")
  if not f then
    return false
  end
  f:write(html)
  f:close()
  return true
end

--- Render `buf` to a PNG asynchronously. Calls `cb(png_path, width_px, height_px)`
--- on success, or `cb(nil, err)` on failure.
local function render_png(buf, width_px, cb)
  local chrome = find_chrome()
  if not chrome then
    return cb(nil, "no Chrome/Chromium found (set preview.chrome)")
  end
  local tmp = state and state.tmpdir or vim.fn.tempname()
  if state then
    state.tmpdir = tmp
  end
  vim.fn.mkdir(tmp, "p")
  local html = tmp .. "/page.html"
  local png = tmp .. "/out.png"
  if not build_html(buf, html) then
    return cb(nil, "failed to build preview HTML")
  end
  local url = "file://" .. html
  local scale = config.opts.preview.scale
  -- Pass 1: render and read back the document height from <body data-h>.
  vim.system(
    { chrome, "--headless=new", "--disable-gpu", "--no-sandbox", "--virtual-time-budget=4000", "--dump-dom", url },
    { text = true, timeout = 30000 },
    vim.schedule_wrap(function(res)
      local height = tonumber((res.stdout or ""):match('data%-h="(%d+)"')) or 1200
      -- Pass 2: screenshot the full page at the requested width/height.
      vim.system({
        chrome, "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
        "--force-device-scale-factor=" .. scale,
        "--screenshot=" .. png,
        "--window-size=" .. width_px .. "," .. height,
        url,
      }, { text = true, timeout = 30000 }, vim.schedule_wrap(function(res2)
        if vim.fn.filereadable(png) == 1 then
          cb(png, width_px * scale, height * scale)
        else
          cb(nil, "Chrome screenshot failed: " .. (res2.stderr or "?"))
        end
      end))
    end)
  )
end

----------------------------------------------------------------------
-- kitty graphics output (via Neovim's own UI output stream)
----------------------------------------------------------------------

--- Wrap a kitty graphics APC in the tmux passthrough envelope so tmux forwards
--- it to the outer terminal: \ePtmux; <esc-doubled seq> \e\\
local function tmux_wrap(seq)
  return "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
end

--- Write raw bytes to the terminal. Use Neovim's UI output stream so the bytes
--- interleave cleanly with its rendering (writing to /dev/tty races the TUI and
--- gets clobbered — this was why the image never appeared).
local function term_write(seq)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(seq)
  else
    io.stdout:write(seq)
    io.stdout:flush()
  end
end

local function emit(seq)
  -- Only the graphics APC (\e_G...) needs passthrough; cursor moves go to tmux.
  if vim.env.TMUX and seq:sub(1, 2) == "\27_" then
    seq = tmux_wrap(seq)
  end
  if M._capture then
    M._capture[#M._capture + 1] = seq
    return
  end
  term_write(seq)
end

--- base64 of a short string (file path) using Neovim's builtin.
local function b64(s)
  return vim.base64.encode(s)
end

local ns = vim.api.nvim_create_namespace("mdrender_preview")

--- Transmit a PNG as a kitty *virtual placement* using Unicode placeholders,
--- sized to cols x rows cells. The image is then displayed by writing
--- placeholder text into the preview buffer (see paint()). file transport.
local function kitty_transmit_virtual(id, png, cols, rows)
  emit(string.format("\27_Ga=T,U=1,i=%d,q=2,f=100,t=f,c=%d,r=%d;%s\27\\", id, cols, rows, b64(png)))
end

--- Delete image id `id` and its placements.
local function kitty_delete(id)
  emit("\27_Ga=d,d=i,i=" .. id .. ",q=2\27\\")
end

----------------------------------------------------------------------
-- geometry + paint
----------------------------------------------------------------------

--- Estimated window pixel width for rendering (cols * cell_w).
local function preview_width_px(win)
  local cw = config.opts.preview.cell_pixels[1]
  return math.max(200, vim.api.nvim_win_get_width(win) * cw)
end

--- Total height of the rendered document in terminal cells.
local function doc_rows(s, cols)
  local cw, ch = config.opts.preview.cell_pixels[1], config.opts.preview.cell_pixels[2]
  local px_h = (cols * cw) * (s.img_h / s.img_w)
  return math.max(1, math.min(kgp.MAX_CELLS, math.floor(px_h / ch + 0.5)))
end

--- Paint the visible slice of the image as placeholder cells in the preview
--- buffer, scrolled to mirror the cursor's position in the source document.
local function paint()
  local s = state
  if not s or not s.id or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  local cols = math.min(kgp.MAX_CELLS, vim.api.nvim_win_get_width(s.win))
  local winrows = vim.api.nvim_win_get_height(s.win)
  local total = s.total_rows or 1

  -- Scroll fraction: mirror the cursor's position within the source document.
  local frac = 0
  if config.opts.preview.follow and vim.api.nvim_win_is_valid(s.src_win) then
    local n = vim.api.nvim_buf_line_count(s.src_buf)
    local cur = vim.api.nvim_win_get_cursor(s.src_win)[1]
    frac = math.min(1, math.max(0, (cur - 1) / math.max(1, n - 1)))
  end
  local top = math.floor(frac * math.max(0, total - winrows) + 0.5)

  local hl = kgp.id_highlight(s.id)
  -- The preview buffer holds `winrows` empty real lines; each gets an *overlay*
  -- virtual-text of its placeholder row. Virtual text (not buffer text) avoids
  -- Neovim mangling the placeholder char + combining diacritics, matching how
  -- snacks.nvim renders kitty placeholders.
  local empty = {}
  for i = 1, winrows do
    empty[i] = ""
  end
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, empty)
  vim.bo[s.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for i = 0, winrows - 1 do
    local img_row = top + i
    if img_row < total then
      pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, i, 0, {
        virt_text = { { kgp.row_string(img_row, cols), hl } },
        virt_text_pos = "overlay",
        virt_text_win_col = 0,
        virt_text_hide = false,
      })
    end
  end
end

local redraw = paint

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

--- Re-render the PNG and swap it in (double-buffered to avoid flicker).
local function refresh()
  local s = state
  if not s or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  local cols = math.min(kgp.MAX_CELLS, vim.api.nvim_win_get_width(s.win))
  local width_px = preview_width_px(s.win)
  render_png(s.src_buf, width_px, function(png, w_or_err, h)
    if not state or state ~= s or not vim.api.nvim_win_is_valid(s.win) then
      return
    end
    if not png then
      vim.notify("[mdrender] preview: " .. tostring(w_or_err), vim.log.levels.ERROR)
      return
    end
    s.img_w, s.img_h = w_or_err, h
    s.total_rows = doc_rows(s, cols)
    local new_id = (s.id == 1) and 2 or 1
    kitty_transmit_virtual(new_id, png, cols, s.total_rows)
    local old = s.id
    s.id = new_id
    paint()
    if old then
      kitty_delete(old)
    end
  end)
end

local pending = false
local function schedule_refresh()
  if pending then
    return
  end
  pending = true
  vim.defer_fn(function()
    pending = false
    refresh()
  end, 150)
end

--- Whether the graphical preview can run here. Unlike inline images, the
--- preview supports tmux as long as `allow-passthrough` is on (we try to enable
--- it). Returns ok, reason.
local function preview_available()
  local supported, term = gpu.detect()
  if not supported then
    return false, "not a kitty-graphics terminal (kitty/Ghostty/WezTerm)"
  end
  if vim.env.TMUX then
    local on = vim.trim(vim.fn.system({ "tmux", "show", "-gv", "allow-passthrough" })) == "on"
    if not on then
      return false,
        "tmux is intercepting the kitty graphics escapes. Enable passthrough, then retry:\n"
          .. "    tmux set -g allow-passthrough on\n"
          .. "  To make it permanent, add this line to ~/.tmux.conf:\n"
          .. "    set -g allow-passthrough on"
    end
    return true
  end
  if term ~= "kitty" and term ~= "ghostty" and term ~= "wezterm" then
    return false, "no kitty graphics protocol on this terminal"
  end
  return true
end

--- Open the preview for the current buffer.
function M.open()
  if state then
    return M.focus_source()
  end
  local ok, reason = preview_available()
  if not ok then
    vim.notify("[mdrender] graphical preview unavailable: " .. reason, vim.log.levels.WARN)
    return
  end
  if not load_assets() then
    vim.notify("[mdrender] preview assets not found on runtimepath", vim.log.levels.ERROR)
    return
  end

  local src_buf = vim.api.nvim_get_current_buf()
  local src_win = vim.api.nvim_get_current_win()
  vim.cmd(config.opts.preview.split == "horizontal" and "botright split" or "botright vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].filetype = "mdrender_preview"
  vim.bo[buf].buftype = "nofile"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].list = false
  vim.wo[win].wrap = false -- one buffer line == one screen row (placeholder grid)
  vim.wo[win].conceallevel = 0
  vim.wo[win].winhighlight = "Normal:Normal"
  -- Fill with blank lines so no '~' end-of-buffer markers show under the image.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("\n", 400), "\n"))

  state = { win = win, buf = buf, src_win = src_win, src_buf = src_buf, id = nil, tmpdir = nil }

  -- Return focus to the source window — you keep editing on the left.
  vim.api.nvim_set_current_win(src_win)

  local group = vim.api.nvim_create_augroup("MdRenderPreview", { clear = true })
  state.group = group
  local refresh_evt = config.opts.preview.refresh == "edit"
      and { "TextChanged", "TextChangedI" }
    or { "BufWritePost" }
  vim.api.nvim_create_autocmd(refresh_evt, {
    group = group,
    buffer = src_buf,
    callback = schedule_refresh,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
    group = group,
    callback = function()
      vim.schedule(redraw)
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = schedule_refresh,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
    group = group,
    callback = function(ev)
      if tostring(ev.match) == tostring(win) or ev.buf == buf or ev.buf == src_buf then
        M.close()
      end
    end,
  })

  refresh()
end

--- Close the preview and clean up the image + window.
function M.close()
  local s = state
  if not s then
    return
  end
  state = nil
  pcall(vim.api.nvim_del_augroup_by_id, s.group)
  if s.id then
    kitty_delete(1)
    kitty_delete(2)
  end
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
end

function M.focus_source()
  if state and vim.api.nvim_win_is_valid(state.src_win) then
    vim.api.nvim_set_current_win(state.src_win)
  end
end

--- Toggle the preview.
function M.toggle()
  if state then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  return state ~= nil
end

-- exposed for tests
M._build_html = build_html
M._find_chrome = find_chrome
M._render_png = render_png
M._available = preview_available
M._tmux_wrap = tmux_wrap

return M
