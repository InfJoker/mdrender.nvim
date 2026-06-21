--- Persistent render sidecar manager.
---
--- Spawns a small Node process (assets/sidecar.js) that itself spawns and OWNS a
--- chrome-headless-shell child and talks to it over CDP. Renders are sent as one
--- JSON line on the node process's stdin; responses come back on stdout.
--- Requests coalesce: while one render is in flight, only the most recent queued
--- request is kept (so fast scrolling doesn't pile up).
---
--- Because node owns chrome and exits when our stdin closes, neither process can
--- be orphaned when Neovim goes away (clean exit or crash).
local M = {}

--- Live state, or nil when stopped.
---@type table|nil
local S = nil

local function send(req, cb)
  S.inflight = true
  S.cb = cb
  -- The node process may have just died (its on_exit is async-scheduled); guard
  -- the write so a render in that window doesn't raise a broken-pipe error.
  local ok = pcall(function()
    S.node:write(vim.json.encode(req) .. "\n")
  end)
  if not ok then
    S.inflight, S.cb = false, nil
    cb({ ok = false, err = "sidecar write failed" })
    -- The pipe is dead; on_stdout will never run to drain a coalesced request,
    -- so fail it here rather than leaving its callback hanging forever.
    if S.next then
      local n = S.next
      S.next = nil
      n.cb({ ok = false, err = "sidecar write failed" })
    end
  end
end

local function on_stdout(data)
  if not S then
    return
  end
  S.buf = S.buf .. data
  while true do
    local nl = S.buf:find("\n")
    if not nl then
      break
    end
    local line = S.buf:sub(1, nl - 1)
    S.buf = S.buf:sub(nl + 1)
    local cb = S.cb
    S.cb, S.inflight = nil, false
    if cb then
      local ok, resp = pcall(vim.json.decode, line)
      cb(ok and resp or { ok = false, err = "bad sidecar response" })
    end
    if S.next then
      local n = S.next
      S.next = nil
      send(n.req, n.cb)
    end
  end
end

--- Start the sidecar. Calls on_ready(true) once renders can be served, or
--- on_ready(false, reason) on failure (so the caller can fall back to the CLI).
function M.start(chrome, on_ready)
  if S and S.ready then
    return on_ready(true)
  end
  if S then
    return on_ready(false, "already starting")
  end
  if vim.fn.executable("node") ~= 1 then
    return on_ready(false, "node not found")
  end
  local js = vim.api.nvim_get_runtime_file("assets/sidecar.js", false)[1]
  if not js then
    return on_ready(false, "sidecar.js not found")
  end

  local notified = false -- ensure on_ready fires exactly once
  local function settle(ok, reason)
    if not notified then
      notified = true
      on_ready(ok, reason)
    end
  end

  S = { ready = false, inflight = false, next = nil, cb = nil, buf = "" }
  S.node = vim.system({ "node", js }, {
    stdin = true,
    env = { MDR_CHROME = chrome },
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          on_stdout(data)
        end)
      end
    end,
    stderr = function(_, data)
      if data and data:find("READY", 1, true) then
        vim.schedule(function()
          if S then
            S.ready = true
            settle(true)
          end
        end)
      end
    end,
  }, vim.schedule_wrap(function()
    -- node exited. If we never stopped it ourselves and it was serving renders,
    -- that's an unexpected death — tell the user. If it never became ready,
    -- report failure so the caller falls back to the CLI path.
    local was_ready = S ~= nil and S.ready
    M.stop()
    if was_ready then
      vim.notify("[mdrender] preview renderer stopped; reopen the preview to restart it", vim.log.levels.WARN)
    end
    settle(false, "sidecar exited before ready")
  end))
end

--- Render a clip. `req` = { html, reload, clipY, clipH, width, scale, out }.
--- Coalesces while busy. cb receives the response table.
function M.render(req, cb)
  if not S or not S.ready then
    return cb({ ok = false, err = "sidecar not ready" })
  end
  if S.inflight then
    S.next = { req = req, cb = cb } -- keep only the latest
  else
    send(req, cb)
  end
end

function M.is_ready()
  return S ~= nil and S.ready == true
end

function M.stop()
  if not S then
    return
  end
  local s = S
  S = nil
  -- SIGTERM (not SIGKILL) so node's handler tears down its chrome child first,
  -- then escalate to SIGKILL if it's still alive (handler wedged/ignored).
  pcall(function()
    if s.node then
      s.node:kill("sigterm")
    end
  end)
  if s.node then
    vim.defer_fn(function()
      pcall(function()
        s.node:kill("sigkill")
      end)
    end, 2000)
  end
end

return M
