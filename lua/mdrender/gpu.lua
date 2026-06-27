--- GPU-accelerated terminal detection.
---
--- "GPU-accelerated" terminals (kitty, ghostty, WezTerm, iTerm2) render their
--- grid on the GPU and, crucially for this plugin, implement a terminal
--- graphics protocol so we can place real images inline. We use detection to
--- decide between Nerd-Font glyphs vs. ASCII and whether inline images are
--- possible at all.
local M = {}

--- Map an outer terminal name (e.g. $TERM or tmux's client_termname) to one of
--- our supported terminal identifiers, or nil.
local function term_name_to_id(name)
  name = name or ""
  if name:find("kitty", 1, true) then
    return "kitty"
  end
  if name:find("ghostty", 1, true) then
    return "ghostty"
  end
  if name:find("wezterm", 1, true) then
    return "wezterm"
  end
  return nil
end

--- The outer terminal tmux is attached to, e.g. "xterm-kitty". Inside tmux $TERM
--- is "screen-256color" and $KITTY_WINDOW_ID doesn't reliably reach every pane,
--- so the env-var probes below miss kitty; tmux itself knows the real terminal.
local function tmux_client_termname()
  if not vim.env.TMUX then
    return nil
  end
  local ok, out = pcall(vim.fn.system, { "tmux", "display", "-p", "#{client_termname}" })
  if not ok then
    return nil
  end
  return vim.trim(out or "")
end

--- Detect whether we are running inside a GPU-accelerated terminal.
---@return boolean supported
---@return string|nil name  terminal identifier when supported
function M.detect()
  local env = vim.env
  local term = env.TERM or ""
  local prog = env.TERM_PROGRAM or ""

  if env.KITTY_WINDOW_ID or term:find("kitty", 1, true) then
    return true, "kitty"
  end
  if env.GHOSTTY_RESOURCES_DIR or term:find("ghostty", 1, true) or prog == "ghostty" then
    return true, "ghostty"
  end
  if env.WEZTERM_PANE or prog == "WezTerm" then
    return true, "wezterm"
  end
  if prog == "iTerm.app" then
    return true, "iterm2"
  end
  -- Inside tmux the env vars above are unreliable; ask tmux for the outer term.
  local id = term_name_to_id(tmux_client_termname())
  if id then
    return true, id
  end
  return false, nil
end

--- Whether tmux is forwarding terminal graphics escapes to the outer terminal.
--- Must be "all", not "on": Neovim runs in the alternate screen, where tmux only
--- forwards graphics passthrough when allow-passthrough is "all". Returns true
--- when not inside tmux at all.
---@return boolean ok
---@return string|nil reason
function M.tmux_passthrough_ok()
  if not vim.env.TMUX then
    return true, nil
  end
  local ok, out = pcall(vim.fn.system, { "tmux", "show", "-gv", "allow-passthrough" })
  if ok and vim.trim(out or "") == "all" then
    return true, nil
  end
  return false,
    "tmux is intercepting the kitty graphics escapes. Enable FULL passthrough, then retry:\n"
      .. "    tmux set -g allow-passthrough all\n"
      .. "  To make it permanent, add to ~/.tmux.conf:\n"
      .. "    set -g allow-passthrough all\n"
      .. "  ('on' is not enough — Neovim's alternate screen needs 'all'.)"
end

--- Whether the kitty graphics protocol is usable for inline images.
--- tmux/screen multiplexers intercept escape sequences and break the protocol
--- unless passthrough is configured, so we require allow-passthrough=all there
--- (mirroring the graphical preview, which already supports tmux passthrough).
---@param term string|nil  detected terminal name
---@return boolean ok
---@return string|nil reason  why it is unavailable
function M.graphics_available(term)
  if term ~= "kitty" and term ~= "ghostty" and term ~= "wezterm" then
    return false, "no kitty graphics protocol support on this terminal"
  end
  if vim.env.TMUX then
    return M.tmux_passthrough_ok()
  end
  return true, nil
end

return M
