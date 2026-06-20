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
-- kitty graphics output (straight to the tty)
----------------------------------------------------------------------

local function tty()
  if state and state.tty then
    return state.tty
  end
  local h = io.open("/dev/tty", "w")
  if state then
    state.tty = h
  end
  return h
end

--- Wrap a kitty graphics APC in the tmux passthrough envelope so tmux forwards
--- it to the outer terminal: \ePtmux; <esc-doubled seq> \e\\
local function tmux_wrap(seq)
  return "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
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
  local h = tty()
  if h then
    h:write(seq)
    h:flush()
  end
end

--- base64 of a short string (file path) using Neovim's builtin.
local function b64(s)
  return vim.base64.encode(s)
end

--- Transmit a PNG file to kitty under image id `id` (a=t, file transport).
local function kitty_transmit(id, png)
  emit("\27_Ga=t,t=f,f=100,i=" .. id .. ",q=2;" .. b64(png) .. "\27\\")
end

--- Delete image id `id` and all its placements.
local function kitty_delete(id)
  emit("\27_Ga=d,d=i,i=" .. id .. ",q=2\27\\")
end

--- Place a cropped slice of image `id` into the preview window.
---@param id integer
---@param win integer  preview window
---@param src_y integer  top of the source crop, in image pixels
---@param crop_h integer  height of the source crop, in image pixels
---@param img_w integer
local function kitty_place(id, win, src_y, crop_h, img_w)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local pos = vim.api.nvim_win_get_position(win)
  local cols = vim.api.nvim_win_get_width(win)
  local rows = vim.api.nvim_win_get_height(win)
  -- Move the real cursor to the window's top-left cell (1-based), place, and
  -- leave the cursor put (C=1).
  emit(string.format("\27[%d;%dH", pos[1] + 1, pos[2] + 1))
  emit(string.format(
    "\27_Ga=p,i=%d,p=%d,x=0,y=%d,w=%d,h=%d,c=%d,r=%d,C=1,q=2\27\\",
    id, id, math.max(0, src_y), img_w, math.max(1, crop_h), cols, rows
  ))
end

----------------------------------------------------------------------
-- geometry + redraw
----------------------------------------------------------------------

--- Estimated window pixel width for rendering (cols * cell_w).
local function preview_width_px(win)
  local cw = config.opts.preview.cell_pixels[1]
  return math.max(200, vim.api.nvim_win_get_width(win) * cw)
end

--- Compute the vertical source crop for the current source-window scroll.
local function compute_crop(s)
  local cw, ch = config.opts.preview.cell_pixels[1], config.opts.preview.cell_pixels[2]
  local cols = vim.api.nvim_win_get_width(s.win)
  local rows = vim.api.nvim_win_get_height(s.win)
  -- Crop aspect must match the window aspect so the image isn't distorted.
  local crop_h = math.floor(s.img_w * (rows * ch) / (cols * cw))
  crop_h = math.min(crop_h, s.img_h)
  -- Scroll fraction from the source window's first visible line.
  local frac = 0
  if config.opts.preview.follow and vim.api.nvim_win_is_valid(s.src_win) then
    local total = vim.api.nvim_buf_line_count(s.src_buf)
    local vis = vim.api.nvim_win_get_height(s.src_win)
    local w0 = vim.api.nvim_win_call(s.src_win, function()
      return vim.fn.line("w0")
    end)
    local denom = math.max(1, total - vis)
    frac = math.min(1, math.max(0, (w0 - 1) / denom))
  end
  local src_y = math.floor(frac * math.max(0, s.img_h - crop_h))
  return src_y, crop_h
end

--- Re-place the current image for the current scroll position.
local function redraw()
  local s = state
  if not s or not s.id or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  local src_y, crop_h = compute_crop(s)
  kitty_place(s.id, s.win, src_y, crop_h, s.img_w)
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

--- Re-render the PNG and swap it in (double-buffered to avoid flicker).
local function refresh()
  local s = state
  if not s or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  local width_px = preview_width_px(s.win)
  render_png(s.src_buf, width_px, function(png, w_or_err, h)
    if not state or state ~= s or not vim.api.nvim_win_is_valid(s.win) then
      return
    end
    if not png then
      vim.notify("[mdrender] preview: " .. tostring(w_or_err), vim.log.levels.ERROR)
      return
    end
    local new_id = (s.id == 1) and 2 or 1
    kitty_transmit(new_id, png)
    s.img_w, s.img_h = w_or_err, h
    local old = s.id
    s.id = new_id
    redraw()
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
  vim.wo[win].winhighlight = "Normal:Normal"
  -- Fill with blank lines so no '~' end-of-buffer markers show under the image.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("\n", 400), "\n"))

  state = { win = win, buf = buf, src_win = src_win, src_buf = src_buf, id = nil, tmpdir = nil, tty = nil }

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
  if s.tty then
    pcall(function()
      s.tty:close()
    end)
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
