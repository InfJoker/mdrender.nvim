--- GPU-accelerated terminal detection.
---
--- "GPU-accelerated" terminals (kitty, ghostty, WezTerm, iTerm2) render their
--- grid on the GPU and, crucially for this plugin, implement a terminal
--- graphics protocol so we can place real images inline. We use detection to
--- decide between Nerd-Font glyphs vs. ASCII and whether inline images are
--- possible at all.
local M = {}

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
  return false, nil
end

--- Whether the kitty graphics protocol is usable for inline images.
--- tmux/screen multiplexers intercept escape sequences and break it unless
--- passthrough is configured, so we conservatively decline inside them.
---@param term string|nil  detected terminal name
---@return boolean ok
---@return string|nil reason  why it is unavailable
function M.graphics_available(term)
  if term ~= "kitty" and term ~= "ghostty" and term ~= "wezterm" then
    return false, "no kitty graphics protocol support on this terminal"
  end
  if vim.env.TMUX then
    return false, "running inside tmux (graphics passthrough not enabled)"
  end
  return true, nil
end

return M
