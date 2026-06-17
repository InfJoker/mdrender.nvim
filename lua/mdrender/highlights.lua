--- Highlight group definitions for mdrender.
--- All groups are defined with `default = true` so user colorschemes win.
local M = {}

-- A Tokyo-Night-ish palette that reads well on true-color GPU terminals.
M.groups = {
  MdRenderH1 = { fg = "#f7768e", bold = true },
  MdRenderH2 = { fg = "#ff9e64", bold = true },
  MdRenderH3 = { fg = "#e0af68", bold = true },
  MdRenderH4 = { fg = "#9ece6a", bold = true },
  MdRenderH5 = { fg = "#2ac3de", bold = true },
  MdRenderH6 = { fg = "#bb9af7", bold = true },

  MdRenderBold = { bold = true },
  MdRenderItalic = { italic = true },
  MdRenderBoldItalic = { bold = true, italic = true },
  MdRenderStrike = { strikethrough = true },

  MdRenderCode = { bg = "#1b1d2b" }, -- fenced block background
  MdRenderCodeInline = { bg = "#2d3149", fg = "#c0caf5" },
  MdRenderCodeLang = { fg = "#7aa2f7", bg = "#1b1d2b", bold = true },

  MdRenderBullet = { fg = "#7aa2f7" },
  MdRenderOrdered = { fg = "#7aa2f7", bold = true },

  MdRenderCheck = { fg = "#73daca", bold = true },
  MdRenderCheckDone = { fg = "#565f89", strikethrough = true },

  MdRenderQuote = { fg = "#9d7cd8", italic = true },

  MdRenderRule = { fg = "#3b4261", bold = true },

  MdRenderLink = { fg = "#7dcfff", underline = true },
  MdRenderLinkIcon = { fg = "#7dcfff" },

  MdRenderTable = { fg = "#3b4261" }, -- borders
  MdRenderTableHead = { fg = "#7aa2f7", bold = true },
  MdRenderTableCell = { link = "Normal" },

  -- Callouts / GitHub alerts (title + left bar, per type).
  MdRenderCalloutNote = { fg = "#7aa2f7", bold = true },
  MdRenderCalloutTip = { fg = "#9ece6a", bold = true },
  MdRenderCalloutImportant = { fg = "#bb9af7", bold = true },
  MdRenderCalloutWarning = { fg = "#e0af68", bold = true },
  MdRenderCalloutCaution = { fg = "#f7768e", bold = true },
}

--- Register all highlight groups (idempotent).
function M.setup()
  for name, attrs in pairs(M.groups) do
    local def = vim.deepcopy(attrs)
    def.default = true
    vim.api.nvim_set_hl(0, name, def)
  end
end

return M
