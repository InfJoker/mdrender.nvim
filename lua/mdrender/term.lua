--- Shared kitty-graphics terminal output.
---
--- One implementation of "get kitty escape sequences onto the real terminal,
--- correctly, including through tmux". Both the graphical preview
--- (`preview.lua`) and inline images (`image.lua`) use it, so the hard-won tmux
--- details (direct `t=d` transport, passthrough wrapping, the real tty device
--- path) live in exactly one place and can't drift apart between the two paths.
local M = {}

--- Wrap a kitty graphics APC in the tmux passthrough envelope so tmux forwards
--- it to the outer terminal: \ePtmux; <esc-doubled seq> \e\\
function M.tmux_wrap(seq)
  return "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
end

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
M._tty_path = tty_path

--- Write raw bytes to the terminal. Plain io.stdout (C stdio) races Neovim's
--- libuv TUI writes on fd 1 and the sequence gets split/clobbered (flaky or
--- blank). Prefer nvim_ui_send (0.11+) — the official channel — else write to
--- the tty device (a separate fd from Neovim's fd-1 TUI writes), each complete
--- escape sequence in one flushed write so the TUI can't split it.
local tty_handle = nil
local function term_write(seq)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(seq)
    return
  end
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

--- When set to a table, emitted sequences are captured into it instead of being
--- written to the terminal (used by tests/headless verification).
M._capture = nil

--- Emit one complete escape sequence. Graphics APCs (\e_G…) are wrapped for tmux
--- passthrough when running inside tmux; cursor moves and the like are not.
function M.emit(seq)
  if vim.env.TMUX and seq:sub(1, 2) == "\27_" then
    seq = M.tmux_wrap(seq)
  end
  if M._capture then
    M._capture[#M._capture + 1] = seq
    return
  end
  term_write(seq)
end

--- Transmit a PNG and create a kitty virtual placement (Unicode placeholders),
--- sized to cols x rows cells. Uses *direct* data transport (t=d), sending the
--- base64 PNG bytes in 4 KiB chunks — file transport (t=f) fails to open the
--- file across tmux/sandboxing (kitty returns EBADF), direct data always works.
--- Returns true on success.
function M.transmit_virtual(id, png, cols, rows)
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
      M.emit(string.format("\27_Ga=t,f=100,t=d,i=%d,q=2,m=%d;%s\27\\", id, more, chunk))
      first = false
    else
      M.emit(string.format("\27_Gm=%d;%s\27\\", more, chunk))
    end
  end
  -- create the virtual placement that the placeholder cells reference
  M.emit(string.format("\27_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\27\\", id, cols, rows))
  return true
end

--- Delete image id `id` and its placements.
function M.delete(id)
  M.emit("\27_Ga=d,d=i,i=" .. id .. ",q=2\27\\")
end

--- Delete every transmitted image (a=d with no target).
function M.delete_all()
  M.emit("\27_Ga=d,q=2\27\\")
end

return M
