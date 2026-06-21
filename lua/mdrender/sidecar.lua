--- Persistent render sidecar manager.
---
--- Keeps a warm chrome-headless-shell (started with a debug port) plus a small
--- Node process (assets/sidecar.js) that talks to it over CDP. Renders are sent
--- as one JSON line on the node process's stdin; responses come back on stdout.
--- Requests coalesce: while one render is in flight, only the most recent queued
--- request is kept (so fast scrolling doesn't pile up).
local uv = vim.uv or vim.loop

local M = {}

--- Live state, or nil when stopped.
---@type table|nil
local S = nil

--- Read the chosen debug port from chrome's DevToolsActivePort file.
local function read_port(dir)
  local f = io.open(dir .. "/DevToolsActivePort", "r")
  if not f then
    return nil
  end
  local line = f:read("l")
  f:close()
  return line and tonumber(line)
end

local function send(req, cb)
  S.inflight = true
  S.cb = cb
  S.node:write(vim.json.encode(req) .. "\n")
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

--- Start the node sidecar against the (now known) chrome port.
local function start_node(on_ready)
  if vim.fn.executable("node") ~= 1 then
    M.stop()
    return on_ready(false, "node not found")
  end
  local js = vim.api.nvim_get_runtime_file("assets/sidecar.js", false)[1]
  if not js then
    M.stop()
    return on_ready(false, "sidecar.js not found")
  end
  S.node = vim.system({ "node", js }, {
    stdin = true,
    env = { MDR_CDP_PORT = tostring(S.port) },
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          on_stdout(data)
        end)
      end
    end,
    stderr = function(_, data)
      if data and data:find("READY", 1, true) and S and not S.ready then
        S.ready = true
        vim.schedule(function()
          on_ready(true)
        end)
      end
    end,
  }, vim.schedule_wrap(function()
    M.stop()
  end))
end

--- Start chrome + node. Calls on_ready(true) when renders can be served, or
--- on_ready(false, reason) on failure.
function M.start(chrome, on_ready)
  if S and S.ready then
    return on_ready(true)
  end
  if S then
    return on_ready(false, "already starting")
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local chrome_obj = vim.system({
    chrome, "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
    "--allow-file-access-from-files", "--remote-allow-origins=*",
    "--remote-debugging-port=0", "--user-data-dir=" .. dir, "about:blank",
  }, {}, function() end)
  S = { chrome = chrome_obj, dir = dir, ready = false, inflight = false, next = nil, cb = nil, buf = "" }

  local tries = 0
  local timer = uv.new_timer()
  timer:start(40, 40, vim.schedule_wrap(function()
    if not S then
      timer:stop()
      timer:close()
      return
    end
    tries = tries + 1
    local port = read_port(dir)
    if port then
      timer:stop()
      timer:close()
      S.port = port
      start_node(on_ready)
    elseif tries > 150 then -- ~6s
      timer:stop()
      timer:close()
      M.stop()
      on_ready(false, "chrome debug port never opened")
    end
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
  pcall(function()
    if s.node then
      s.node:kill(9)
    end
  end)
  pcall(function()
    if s.chrome then
      s.chrome:kill(9)
    end
  end)
end

return M
