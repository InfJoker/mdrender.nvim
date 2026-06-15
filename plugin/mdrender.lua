--- Plugin entry point. Registers the :MdRender command and an autocommand that
--- attaches decorations the first time a markdown buffer appears. Keeps startup
--- cheap: nothing heavy runs until a markdown filetype is actually seen.
if vim.g.loaded_mdrender then
  return
end
vim.g.loaded_mdrender = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.schedule(function()
    vim.notify("[mdrender] requires Neovim 0.10+", vim.log.levels.ERROR)
  end)
  return
end

vim.api.nvim_create_user_command("MdRender", function(o)
  require("mdrender")._command(o.fargs)
end, {
  nargs = "*",
  complete = function(arglead)
    return vim.tbl_filter(function(c)
      return c:find(arglead, 1, true) == 1
    end, { "toggle", "enable", "disable", "status", "image" })
  end,
  desc = "Control mdrender markdown decorations",
})

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("MdRenderBootstrap", { clear = true }),
  callback = function(ev)
    local md = require("mdrender")
    -- Auto-configure with defaults if the user never called setup().
    if not md._configured then
      md.setup()
    end
    md._on_filetype(ev.buf)
  end,
})
