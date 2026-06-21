--- Graphical Markdown preview.
---
--- Renders the current buffer to a styled PNG with headless Chrome (HTML + an
--- styled CSS theme, marked + highlight.js running client-side), then
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
local sidecar = require("mdrender.sidecar")

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
    hlcss = read("highlight-dark.css"),
    marked = read("marked.min.js"),
    hljs = read("highlight.min.js"),
  }
  return assets
end

--- Find an installed chrome-headless-shell (a lightweight headless Chrome that
--- cold-starts in ~0.25s vs ~2s for full Chrome). Installed via:
---   npx @puppeteer/browsers install chrome-headless-shell@stable
local function find_headless_shell()
  -- @puppeteer/browsers nests it differently depending on the --path used
  -- (e.g. ~/chrome-headless-shell/<ver>/... vs
  -- ~/.cache/puppeteer/chrome-headless-shell/<ver>/...), so glob recursively.
  for _, root in ipairs({ "~/.cache/puppeteer", "~/chrome-headless-shell" }) do
    local hits = vim.fn.glob(vim.fn.expand(root) .. "/**/chrome-headless-shell-*/chrome-headless-shell", true, true)
    if hits[1] and vim.fn.executable(hits[1]) == 1 then
      return hits[1]
    end
  end
  return nil
end

--- Whether the resolved chrome binary is the fast headless-shell.
local using_shell = false

--- Locate a Chrome binary. Prefers chrome-headless-shell (much faster), then
--- full Chrome/Chromium as a (slower) fallback.
local function find_chrome()
  if config.opts.preview.chrome then
    return config.opts.preview.chrome
  end
  local shell = find_headless_shell()
  if shell then
    using_shell = true
    return shell
  end
  using_shell = false
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
  -- Shared flags tuned for a fast cold start. --allow-file-access-from-files lets
  -- the page load local ![](images) referenced relative to the markdown file.
  -- Note: --user-data-dir is intentionally NOT used. With a persistent profile
  -- Chrome becomes a singleton that stays alive, so vim.system's stdout never
  -- closes and the callback never fires.
  local base = {
    chrome, "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
    "--no-first-run", "--no-default-browser-check", "--disable-extensions",
    "--disable-background-networking", "--disable-sync", "--disable-default-apps",
    "--mute-audio", "--disable-features=Translate,BackForwardCache",
    "--allow-file-access-from-files", "--disable-dev-shm-usage",
  }
  local function run(extra, on_done)
    local cmd = vim.list_extend(vim.deepcopy(base), extra)
    vim.system(cmd, { text = true, timeout = 30000 }, vim.schedule_wrap(on_done))
  end
  -- Pass 1: render and read back the document height from <body data-h>.
  -- The page's inline script renders synchronously before load, so --dump-dom
  -- already sees data-h — no virtual-time-budget needed.
  run({ "--virtual-time-budget=400", "--dump-dom", url }, function(res)
    local height = tonumber((res.stdout or ""):match('data%-h="(%d+)"')) or 1200
    -- Pass 2: screenshot the full page at the requested width/height.
    run({
      "--force-device-scale-factor=" .. scale,
      "--screenshot=" .. png,
      "--window-size=" .. width_px .. "," .. height,
      url,
    }, function(res2)
      if vim.fn.filereadable(png) == 1 then
        cb(png, width_px * scale, height * scale)
      else
        cb(nil, "Chrome screenshot failed: " .. (res2.stderr or "?"))
      end
    end)
  end)
end

----------------------------------------------------------------------
-- kitty graphics output (via Neovim's own UI output stream)
----------------------------------------------------------------------

--- Wrap a kitty graphics APC in the tmux passthrough envelope so tmux forwards
--- it to the outer terminal: \ePtmux; <esc-doubled seq> \e\\
local function tmux_wrap(seq)
  return "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
end

--- Write raw bytes to the terminal. Plain io.stdout (C stdio) races Neovim's
--- libuv TUI writes on fd 1 and the sequence gets split/clobbered (flaky or
--- blank). Instead write through a libuv TTY handle on fd 1 — the same queue
--- Neovim's UI uses — so the bytes are ordered cleanly. Prefer nvim_ui_send
--- (0.11+) when available; it's the official channel.
--- Resolve the real terminal device path (e.g. /dev/ttys008). The generic
--- /dev/tty alias fails to open when Neovim has no controlling terminal (e.g.
--- launched via `open`/launchd), but the concrete device — reported by `tty`,
--- whose stdin Neovim inherits — opens fine. This is how image.nvim does it.
local function tty_path()
  local p = io.popen("tty 2>/dev/null")
  if not p then
    return nil
  end
  local t = (p:read("*a") or ""):gsub("%s+$", "")
  p:close()
  return t:match("^/dev/") and t or nil
end

local tty_handle = nil
local function term_write(seq)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(seq)
    return
  end
  -- Write to the tty device (a separate fd from Neovim's fd-1 TUI writes), each
  -- complete escape sequence in one flushed write so the TUI can't split it.
  if tty_handle == nil then
    tty_handle = io.open(tty_path() or "/dev/tty", "w") or false
  end
  if tty_handle then
    tty_handle:write(seq)
    tty_handle:flush()
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

local ns = vim.api.nvim_create_namespace("mdrender_preview")

-- The two kitty image ids we double-buffer between. Derived from our pid so we
-- don't clobber image ids another graphics plugin (or another nvim sharing this
-- kitty window via tmux) is using; kept within 24 bits (the placeholder encodes
-- the id in the cell foreground colour).
local ID_A = 0x6d6400 + (vim.fn.getpid() % 0x600) * 2
local ID_B = ID_A + 1

--- Transmit a PNG and create a kitty virtual placement (Unicode placeholders),
--- sized to cols x rows cells. Uses *direct* data transport (t=d), sending the
--- base64 PNG bytes in 4 KiB chunks — file transport (t=f) fails to open the
--- file across tmux/sandboxing (kitty returns EBADF), direct data always works.
local function kitty_transmit_virtual(id, png, cols, rows)
  local f = io.open(png, "rb")
  if not f then
    return false
  end
  local data = f:read("*a")
  f:close()
  local b64 = vim.base64.encode(data)
  local CHUNK, n, i = 4096, #b64, 1
  if n == 0 then
    return false
  end
  local first = true
  while i <= n do
    local chunk = b64:sub(i, i + CHUNK - 1)
    i = i + CHUNK
    local more = (i <= n) and 1 or 0
    if first then
      emit(string.format("\27_Ga=t,f=100,t=d,i=%d,q=2,m=%d;%s\27\\", id, more, chunk))
      first = false
    else
      emit(string.format("\27_Gm=%d;%s\27\\", more, chunk))
    end
  end
  -- create the virtual placement that the placeholder cells reference
  emit(string.format("\27_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\27\\", id, cols, rows))
  return true
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

--- Scroll fraction: the cursor's position within the source document (0..1).
local function scroll_frac(s)
  if config.opts.preview.follow and vim.api.nvim_win_is_valid(s.src_win) then
    local n = vim.api.nvim_buf_line_count(s.src_buf)
    local cur = vim.api.nvim_win_get_cursor(s.src_win)[1]
    return math.min(1, math.max(0, (cur - 1) / math.max(1, n - 1)))
  end
  return 0
end

--- Image row that should sit at the top of the viewport for the current cursor.
--- Sidecar bands map doc pixels 1:1 within the band (offset by band_y0); the CLI
--- image is the whole doc scaled into `total` rows.
local function top_row(s, winrows, total)
  local ch = config.opts.preview.cell_pixels[2]
  local top
  if s.band_y0 ~= nil and s.doc_h then
    local target_y = scroll_frac(s) * math.max(0, s.doc_h - winrows * ch)
    top = math.floor((target_y - s.band_y0) / ch + 0.5)
  else
    top = math.floor(scroll_frac(s) * math.max(0, total - winrows) + 0.5)
  end
  return math.max(0, math.min(top, math.max(0, total - winrows)))
end

--- Paint the WHOLE image as placeholder cells — one buffer line per image row.
--- Every row of the kitty placement must be covered by a placeholder or it won't
--- render. The viewport then scrolls *within* this via scroll_view (no re-paint,
--- no transmit), which is what makes scrolling smooth and leak-free.
local function paint_band(s)
  if not s or not s.id or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  local cols = math.min(kgp.MAX_CELLS, vim.api.nvim_win_get_width(s.win))
  local total = s.total_rows or 1
  local hl = kgp.id_highlight(s.id)
  local empty = {}
  for i = 1, total do
    empty[i] = ""
  end
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, empty)
  vim.bo[s.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for img_row = 0, total - 1 do
    pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, img_row, 0, {
      virt_text = { { kgp.row_string(img_row, cols), hl } },
      virt_text_pos = "overlay",
      virt_text_win_col = 0,
      virt_text_hide = false,
    })
  end
end

--- Scroll the preview window so the cursor's image row is at the top. Cheap and
--- smooth: NO Chrome, NO transmit, NO graphics write — just a view move. This is
--- what runs on every scroll within a band, so scrolling never touches the tty.
local function scroll_view(s)
  if not s or not s.id or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  local winrows = vim.api.nvim_win_get_height(s.win)
  local total = s.total_rows or 1
  local top = top_row(s, winrows, total)
  vim.api.nvim_win_call(s.win, function()
    vim.fn.winrestview({ topline = top + 1, lnum = math.min(total, top + 1), col = 0, leftcol = 0 })
  end)
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

--- Show a freshly-rendered band PNG: transmit to the *other* of our two image
--- ids (no re-transmit flash, no delete), paint all its placeholder rows, then
--- scroll the window to the cursor. Transmits happen ONLY here — on a content
--- change or a band-edge crossing — not on every scroll.
local function swap_in(s, png, cols, rows)
  local new_id = (s.id == ID_A) and ID_B or ID_A
  if not kitty_transmit_virtual(new_id, png, cols, rows) then
    return
  end
  s.id = new_id
  paint_band(s)
  scroll_view(s)
end

--- CLI fallback: re-render the whole document with headless Chrome (two passes,
--- ~0.5s). The whole doc maps to the placeholder grid (capped at 297 rows), then
--- the window scrolls within it.
local function refresh_cli()
  local s = state
  if not s or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  local cols = math.min(kgp.MAX_CELLS, vim.api.nvim_win_get_width(s.win))
  render_png(s.src_buf, preview_width_px(s.win), function(png, w_or_err, h)
    if not state or state ~= s or not vim.api.nvim_win_is_valid(s.win) then
      return
    end
    if not png then
      vim.notify("[mdrender] preview: " .. tostring(w_or_err), vim.log.levels.ERROR)
      return
    end
    s.img_w, s.img_h = w_or_err, h
    s.band_y0 = nil -- CLI image is the whole doc, not a pixel band
    s.total_rows = doc_rows(s, cols)
    swap_in(s, png, cols, s.total_rows)
  end)
end

--- Fast path: render a tall BAND (up to maxH px) around the cursor via the
--- persistent sidecar, then scroll within it by moving the window. Only called
--- to (re)render the band — on content change (`reload`) or when scrolling past
--- the band edge — NOT on every scroll. A doc that fits in one band is rendered
--- once and never again.
local function refresh_sidecar(reload)
  local s = state
  if not s or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  if s.band_pending and not reload then
    return -- a band render is already in flight; don't pile on while scrolling
  end
  local cols = math.min(kgp.MAX_CELLS, vim.api.nvim_win_get_width(s.win))
  local cw, ch = config.opts.preview.cell_pixels[1], config.opts.preview.cell_pixels[2]
  local scale = config.opts.preview.scale
  -- Band height is bounded by the 297-cell placeholder limit AND kitty's
  -- ~10000px image cap (image px = bandH*scale). Kept moderate so the (rare)
  -- band transmit stays small enough for tmux passthrough.
  local maxH = math.min(kgp.MAX_CELLS * ch, math.floor(6000 / scale))
  if reload and not build_html(s.src_buf, s.html) then
    return
  end
  local out = s.tmpdir .. (s.id == ID_A and "/b.png" or "/a.png")
  s.band_pending = true
  sidecar.render({
    html = s.html,
    reload = reload and true or false,
    frac = scroll_frac(s),
    maxH = maxH,
    width = cols * cw,
    scale = scale,
    out = out,
  }, function(r)
    if not state or state ~= s then
      return
    end
    s.band_pending = false
    if not r or not r.ok then
      return
    end
    s.doc_h = r.docH
    s.band_y0 = r.bandY or 0
    s.total_rows = math.max(1, math.floor((r.bandH or r.docH) / ch + 0.5))
    swap_in(s, out, cols, s.total_rows)
  end)
end

--- Content changed → full re-render.
local function render_content()
  if state and state.mode == "sidecar" then
    refresh_sidecar(true)
  else
    refresh_cli()
  end
end

--- Scroll / cursor moved → reposition. If the target is inside the current band
--- (or it's the CLI whole-doc image), just scroll the window (smooth, no tty
--- write). Otherwise render a fresh band around the new position.
local function redraw()
  local s = state
  if not s or not s.id then
    return
  end
  if s.mode == "cli" then
    scroll_view(s)
    return
  end
  if s.band_y0 ~= nil and s.doc_h then
    local winrows = vim.api.nvim_win_get_height(s.win)
    local ch = config.opts.preview.cell_pixels[2]
    local target_y = scroll_frac(s) * math.max(0, s.doc_h - winrows * ch)
    local want = math.floor((target_y - s.band_y0) / ch + 0.5)
    scroll_view(s) -- always scroll (clamps into the band)
    if want >= 0 and want + winrows <= (s.total_rows or 0) then
      return -- inside the band — nothing more to do
    end
    -- scrolled past the band edge → render a fresh band around the new position
  end
  refresh_sidecar(false)
end

local pending = false
local function schedule_refresh()
  if pending then
    return
  end
  pending = true
  vim.defer_fn(function()
    pending = false
    render_content()
  end, 120)
end


--- Whether the graphical preview can run here. Unlike inline images, the
--- preview supports tmux as long as `allow-passthrough` is on (we try to enable
--- it). Returns ok, reason.
local function preview_available()
  -- Use the detection cached at setup() rather than re-probing on every open.
  local supported, term = config.gpu, config.term
  if supported == nil then
    supported, term = gpu.detect()
  end
  if not supported then
    return false, "not a kitty-graphics terminal (kitty/Ghostty/WezTerm)"
  end
  if vim.env.TMUX then
    -- Must be "all", not "on": Neovim runs in the alternate screen, where tmux
    -- only forwards graphics passthrough when allow-passthrough is "all".
    local pt = vim.trim(vim.fn.system({ "tmux", "show", "-gv", "allow-passthrough" }))
    if pt ~= "all" then
      return false,
        "tmux is intercepting the kitty graphics escapes. Enable FULL passthrough, then retry:\n"
          .. "    tmux set -g allow-passthrough all\n"
          .. "  To make it permanent, add to ~/.tmux.conf:\n"
          .. "    set -g allow-passthrough all\n"
          .. "  ('on' is not enough — Neovim's alternate screen needs 'all'.)"
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

  local chrome = find_chrome()
  if chrome and not using_shell and not vim.g._mdrender_shell_hint then
    vim.g._mdrender_shell_hint = true
    vim.schedule(function()
      vim.notify(
        "[mdrender] tip: install chrome-headless-shell for a lighter/faster preview:  :MdRender install",
        vim.log.levels.INFO
      )
    end)
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
  vim.wo[win].scrolloff = 0 -- so winrestview() can place the top line exactly
  vim.wo[win].sidescrolloff = 0
  -- Fill with blank lines so no '~' end-of-buffer markers show under the image.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("\n", 400), "\n"))

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  state = {
    win = win,
    buf = buf,
    src_win = src_win,
    src_buf = src_buf,
    id = nil,
    tmpdir = tmpdir,
    html = tmpdir .. "/page.html",
    doc_h = nil,
    mode = "cli", -- upgraded to "sidecar" once it's ready
  }

  -- Return focus to the source window — you keep editing on the left.
  vim.api.nvim_set_current_win(src_win)

  local group = vim.api.nvim_create_augroup("MdRenderPreview", { clear = true })
  state.group = group
  local refresh_evt = config.opts.preview.refresh == "edit"
      and { "TextChanged", "TextChangedI" }
    or { "BufWritePost" }
  -- Filter on the live source buffer rather than binding to a fixed one, so the
  -- preview can be re-targeted to another markdown buffer (see M.retarget).
  vim.api.nvim_create_autocmd(refresh_evt, {
    group = group,
    callback = function(ev)
      if state and ev.buf == state.src_buf then
        schedule_refresh()
      end
    end,
  })
  -- Reposition on scroll/cursor moves. CursorMovedI (every keystroke in insert
  -- mode) is deliberately excluded: re-rendering + writing graphics to the tty
  -- on every keystroke races Neovim's own output and corrupts the display.
  -- WinScrolled still keeps the preview in sync while typing pushes the view.
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
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
  -- Make sure the chrome + node sidecar don't linger if nvim exits.
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.close })

  -- Start the persistent sidecar (warm chrome + node over CDP) for fast,
  -- uncapped, scroll-following renders. The first render waits for it; if it
  -- can't start (no node, etc.) we fall back to the CLI path.
  if chrome and vim.fn.executable("node") == 1 then
    sidecar.start(chrome, function(ok)
      if not state then
        return -- closed while starting
      end
      state.mode = ok and "sidecar" or "cli"
      render_content()
    end)
  else
    render_content()
  end
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
    kitty_delete(ID_A)
    kitty_delete(ID_B)
  end
  sidecar.stop()
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

--- Re-point an open preview at a different markdown buffer/window and re-render.
function M.retarget(buf, win)
  if not state or state.src_buf == buf then
    return
  end
  state.src_buf = buf
  state.src_win = win
  state.doc_h = nil
  state.last_clipY, state.last_cols, state.last_winrows = nil, nil, nil
  render_content() -- reload: rebuild HTML for the new buffer
end

--- Is `win` a normal (non-floating) window showing a real markdown FILE buffer?
local function is_md_source(win, buf)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false -- floating window
  end
  if state and (win == state.win or buf == state.buf) then
    return false -- the preview's own window/buffer
  end
  if vim.bo[buf].buftype ~= "" then
    return false -- nofile / help / terminal / quickfix etc.
  end
  local ft = vim.bo[buf].filetype
  for _, f in ipairs(config.opts.filetypes) do
    if ft == f then
      return true
    end
  end
  return false
end

--- preview.auto entry point: on entering a markdown buffer, open the preview
--- for it, or re-target an already-open preview. No-ops unless preview.auto is
--- set, and stays silent when the terminal can't show a preview.
function M.auto_focus()
  if not config.opts.preview.auto then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_md_source(win, buf) then
    return
  end
  if state then
    -- A preview is already open. Re-target it only if it lives in this tabpage,
    -- so we don't hijack a preview shown in another tab.
    if vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_tabpage(state.win) == vim.api.nvim_win_get_tabpage(win)
    then
      M.retarget(buf, win)
    end
    return
  end
  -- No preview yet: open one, but only where it's actually supported (skip
  -- silently otherwise — don't error on every markdown file).
  if preview_available() then
    M.open()
  end
end

--- Where chrome-headless-shell is installed (a path find_headless_shell() globs).
local INSTALL_PATH = vim.fn.expand("~/.cache/puppeteer")

--- Install the lightweight chrome-headless-shell (~9x faster previews) via
--- Puppeteer's browser installer. Used by `:MdRender install` and as the
--- recommended lazy.nvim `build` step. Safe no-op if it's already present.
---@param cb? fun(ok: boolean)
function M.install(cb)
  cb = cb or function() end
  if find_headless_shell() then
    vim.notify("[mdrender] chrome-headless-shell already installed")
    return cb(true)
  end
  if vim.fn.executable("npx") ~= 1 then
    vim.notify("[mdrender] need Node.js (npx) to install chrome-headless-shell", vim.log.levels.ERROR)
    return cb(false)
  end
  vim.fn.mkdir(INSTALL_PATH, "p")
  vim.notify("[mdrender] installing chrome-headless-shell (one-time download)…")
  vim.system(
    { "npx", "--yes", "@puppeteer/browsers", "install", "chrome-headless-shell@stable", "--path", INSTALL_PATH },
    { text = true },
    vim.schedule_wrap(function(res)
      local ok = res.code == 0 and find_headless_shell() ~= nil
      if ok then
        vim.notify("[mdrender] chrome-headless-shell installed — previews are now ~9x faster.")
      else
        vim.notify("[mdrender] install failed:\n" .. (res.stderr or res.stdout or "?"), vim.log.levels.ERROR)
      end
      cb(ok)
    end)
  )
end

-- exposed for tests
M._build_html = build_html
M._find_chrome = find_chrome
M._render_png = render_png
M._available = preview_available
M._tmux_wrap = tmux_wrap

return M
