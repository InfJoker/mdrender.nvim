--- Configuration store for mdrender.
--- Holds the merged user options plus detected terminal capabilities.
local M = {}

--- Default options. `setup()` deep-merges user overrides on top of these.
M.defaults = {
  -- Master switch.
  enabled = true,
  -- Filetypes the plugin decorates.
  filetypes = { "markdown", "markdown.mdx" },
  -- Only activate on a GPU-accelerated terminal (kitty/ghostty/wezterm/iTerm2).
  -- When false the plugin still works everywhere but downgrades Nerd-Font icons
  -- to ASCII and keeps inline images disabled.
  require_gpu = false,
  -- Reveal the raw markdown on the line the cursor sits on (for editing).
  anti_conceal = true,
  -- Conceal level applied to decorated windows.
  conceal_level = 2,
  -- Editor modes in which decorations are shown. Insert ("i") is intentionally
  -- omitted so the raw source appears while you type.
  render_modes = { "n", "v", "V", "\22", "c", "t" },

  heading = {
    enabled = true,
    -- Nerd-Font glyphs (used on GPU terminals).
    icons = { "󰲡 ", "󰲣 ", "󰲥 ", "󰲧 ", "󰲩 ", "󰲫 " },
    -- ASCII fallback.
    ascii = { "# ", "## ", "### ", "#### ", "##### ", "###### " },
    -- Draw a GitHub-style full-width underline below headings up to this level.
    underline = 2,
  },

  bullet = {
    enabled = true,
    icons = { "●", "○", "◆", "◇" },
    ascii = { "*", "-", "+", "·" },
  },

  checkbox = {
    enabled = true,
    unchecked = { icon = "󰄱 ", ascii = "[ ] " },
    checked = { icon = "󰱒 ", ascii = "[x] " },
  },

  quote = { enabled = true, icon = "▋ ", ascii = "| " },

  code = {
    enabled = true,
    -- "full" paints the whole block background; "none" leaves it plain.
    style = "full",
    -- Show a language label on the opening fence.
    language = true,
    lang_icon = "󰅴 ",
  },

  dash = { enabled = true, icon = "─", ascii = "-" },

  link = {
    enabled = true,
    icon = "󰌷 ",
    image_icon = "󰥶 ",
  },

  table = { enabled = true },

  -- Callouts / GitHub alerts: > [!NOTE], [!TIP], [!WARNING], …
  callout = {
    enabled = true,
    -- type -> { icon, hl, title }. Unlisted types fall back to "note".
    types = {
      note = { icon = "󰋽 ", hl = "MdRenderCalloutNote", title = "Note" },
      tip = { icon = "󰌶 ", hl = "MdRenderCalloutTip", title = "Tip" },
      important = { icon = "󰅾 ", hl = "MdRenderCalloutImportant", title = "Important" },
      warning = { icon = "󰀪 ", hl = "MdRenderCalloutWarning", title = "Warning" },
      caution = { icon = "󰳦 ", hl = "MdRenderCalloutCaution", title = "Caution" },
      -- common aliases
      info = { icon = "󰋽 ", hl = "MdRenderCalloutNote", title = "Info" },
      hint = { icon = "󰌶 ", hl = "MdRenderCalloutTip", title = "Hint" },
      success = { icon = "󰄬 ", hl = "MdRenderCalloutTip", title = "Success" },
      question = { icon = "󰘥 ", hl = "MdRenderCalloutWarning", title = "Question" },
      todo = { icon = "󰗡 ", hl = "MdRenderCalloutNote", title = "Todo" },
      danger = { icon = "󱐌 ", hl = "MdRenderCalloutCaution", title = "Danger" },
      bug = { icon = "󰨰 ", hl = "MdRenderCalloutCaution", title = "Bug" },
      example = { icon = "󰉹 ", hl = "MdRenderCalloutImportant", title = "Example" },
    },
  },

  -- Graphical preview: renders the buffer to an image with
  -- headless Chrome and shows it in a split via the kitty graphics protocol.
  preview = {
    chrome = nil, -- path to Chrome/Chromium; nil => autodetect
    cell_pixels = { 8, 17 }, -- { width, height } per cell, for geometry/aspect
    scale = 2, -- device scale factor (crisper text)
    refresh = "save", -- "save" (BufWritePost) or "edit" (debounced TextChanged)
    follow = true, -- scroll the preview to follow the source window
    split = "vertical", -- "vertical" | "horizontal"
  },

  -- Inline image rendering via the kitty graphics protocol. Experimental and
  -- off by default; requires a GPU terminal and (for non-PNG) ImageMagick.
  images = {
    enabled = false,
    max_width = 80, -- maximum width in terminal cells
    cell_pixels = { 8, 17 }, -- approximate cell { width, height } in pixels
  },
}

--- Active merged options (populated by setup()).
M.opts = vim.deepcopy(M.defaults)
--- Whether the host terminal is GPU-accelerated.
M.gpu = false
--- Detected terminal name (e.g. "kitty"), or nil.
M.term = nil

--- Deep-merge user options over the defaults.
---@param opts table|nil
function M.merge(opts)
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.opts
end

return M
