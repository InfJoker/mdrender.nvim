--- mdrender — in-buffer markdown rendering for Neovim, tuned for
--- GPU-accelerated terminals.
---
--- Usage:
---   require("mdrender").setup({ ... })  -- optional; sensible defaults apply
---
--- Commands:
---   :MdRender toggle | enable | disable | status | image
local config = require("mdrender.config")
local highlights = require("mdrender.highlights")
local gpu = require("mdrender.gpu")
local render = require("mdrender.render")

local M = {}

M._configured = false
local notified_gpu = false

--- True when this buffer's filetype is one we decorate.
local function is_markdown(buf)
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  for _, f in ipairs(config.opts.filetypes) do
    if ft == f then
      return true
    end
  end
  return false
end

--- Decide whether decorations may run given the GPU gating policy.
local function gpu_gate_ok()
  if not config.opts.require_gpu then
    return true
  end
  if not config.gpu and not notified_gpu then
    notified_gpu = true
    vim.notify(
      "[mdrender] require_gpu is set but this is not a GPU-accelerated terminal; decorations disabled.",
      vim.log.levels.WARN
    )
  end
  return config.gpu
end

--- Called for every buffer entering a markdown filetype.
function M._on_filetype(buf)
  if not config.opts.enabled or not is_markdown(buf) or not gpu_gate_ok() then
    return
  end
  render.attach(buf)
end

--- Configure the plugin. Safe to call multiple times.
---@param opts table|nil
function M.setup(opts)
  config.merge(opts)
  local supported, term = gpu.detect()
  config.gpu = supported
  config.term = term

  highlights.setup()
  -- Re-apply highlights after a colorscheme change so `default = true` groups
  -- keep their fallbacks.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("MdRenderColors", { clear = true }),
    callback = highlights.setup,
  })

  -- Images need both the user opt-in and a working graphics protocol.
  if config.opts.images.enabled then
    local ok, reason = gpu.graphics_available(term)
    if not ok then
      config.opts.images.enabled = false
      vim.schedule(function()
        vim.notify("[mdrender] inline images disabled: " .. reason, vim.log.levels.INFO)
      end)
    end
  end

  -- preview.auto: open/re-target the graphical preview as you move between
  -- markdown buffers. The handler itself no-ops unless preview.auto is set and
  -- guards against splits/floats/tabs/the preview's own buffer.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("MdRenderAutoPreview", { clear = true }),
    callback = function()
      if config.opts.preview.auto then
        vim.schedule(function()
          pcall(require("mdrender.preview").auto_focus)
        end)
      end
    end,
  })

  M._configured = true

  -- Attach to any markdown buffers already open (e.g. after a lazy setup).
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M._on_filetype(buf)
    end
  end

  -- The buffer that triggered this setup() (lazy ft-load) already fired its
  -- BufWinEnter before our autocmd existed — kick the auto-preview for it.
  if config.opts.preview.auto then
    vim.schedule(function()
      pcall(require("mdrender.preview").auto_focus)
    end)
  end
end

--- Enable decorations for a buffer (defaults to current).
function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  config.opts.enabled = true
  render.attach(buf)
end

--- Disable decorations for a buffer (defaults to current).
function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  render.detach(buf)
end

--- Toggle decorations for a buffer (defaults to current).
function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if render.is_attached(buf) then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

--- Force-render the image under the cursor (manual trigger for :MdRender image).
local function image_under_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line = vim.api.nvim_get_current_line()
  local src = line:match("!%[[^%]]*%]%(([^%)]+)%)") or line:match("%[[^%]]*%]%(([^%)]+)%)")
  if not src then
    vim.notify("[mdrender] no image/link under cursor", vim.log.levels.WARN)
    return
  end
  config.opts.images.enabled = true
  local ok = require("mdrender.image").render_one(buf, row, src)
  if not ok then
    vim.notify("[mdrender] could not render image (need a kitty-protocol terminal & readable file)", vim.log.levels.WARN)
  end
end

--- Implementation of the :MdRender user command.
function M._command(args)
  local sub = args[1] or "toggle"
  if sub == "toggle" then
    M.toggle()
  elseif sub == "enable" then
    M.enable()
  elseif sub == "disable" then
    M.disable()
  elseif sub == "image" then
    image_under_cursor()
  elseif sub == "preview" then
    require("mdrender.preview").toggle()
  elseif sub == "install" then
    require("mdrender.preview").install()
  elseif sub == "status" then
    local buf = vim.api.nvim_get_current_buf()
    vim.notify(string.format(
      "[mdrender] attached=%s  gpu=%s  terminal=%s  images=%s",
      tostring(render.is_attached(buf)),
      tostring(config.gpu),
      tostring(config.term or "n/a"),
      tostring(config.opts.images.enabled)
    ))
  else
    vim.notify("[mdrender] unknown subcommand: " .. sub, vim.log.levels.ERROR)
  end
end

return M
