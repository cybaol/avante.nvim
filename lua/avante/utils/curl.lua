---@mod avante-utils-curl Curl wrapper
---@brief [[
---
--- HTTP GET/POST requests using curl. URLs, headers, auth and proxies are passed
--- as command-line arguments. The request body is sent through stdin.
--- Requests do not follow redirects or load the default curl config.
--- Requests time out after 30 seconds unless opts.timeout overrides the limit.
--- Async processes still running one second after timeout are killed.
--- URLs, header names and values, auth and proxies must not contain NUL, CR or LF.
--- Response bodies are returned unchanged.
---
---@brief ]]

---@class avante.utils.curl.Response
---@field status integer
---@field body string
---@field exit integer

---@class avante.utils.curl.Error
---@field message string
---@field stderr string
---@field exit integer

---@class avante.utils.curl.Options
---@field headers? table<string, string>
---@field body? string
---@field auth? string
---@field timeout? integer Timeout in milliseconds (default: 30000)
---@field proxy? string
---@field insecure? boolean
---@field callback? fun(response: avante.utils.curl.Response)
---@field on_error? fun(err: avante.utils.curl.Error)

local M = {}

---@param value string
---@return string
local function request_value(value)
  if value:find("[\r\n%z]") then error("curl request values must not contain NUL, CR or LF", 0) end
  return value
end

---@param method "GET"|"POST"
---@param url string
---@param opts? avante.utils.curl.Options
---@return avante.utils.curl.Response|vim.SystemObj
local function request(method, url, opts)
  opts = opts or {}
  local timeout = opts.timeout or 30000
  local args = {
    "curl",
    "--disable",
    "--silent",
    "--show-error",
    "--request",
    method,
    "--write-out",
    "\n%{http_code}",
  }
  vim.list_extend(args, { "--url", request_value(url) })
  if opts.auth then vim.list_extend(args, { "--user", request_value(opts.auth) }) end
  if opts.proxy then vim.list_extend(args, { "--proxy", request_value(opts.proxy) }) end
  for name, value in pairs(opts.headers or {}) do
    if name:find("[\r\n%z]") or value:find("[\r\n%z]") then
      error("curl header names and values must not contain NUL, CR or LF", 0)
    end
    vim.list_extend(args, { "--header", name:gsub("_", "-") .. ": " .. value })
  end
  if opts.body then vim.list_extend(args, { "--data-binary", "@-" }) end
  if opts.insecure then table.insert(args, "--insecure") end
  if package.config:sub(1, 1) ~= "\\" then table.insert(args, "--compressed") end

  ---@type uv.uv_timer_t|nil
  local kill_timer
  ---@param result vim.SystemCompleted
  ---@return avante.utils.curl.Response
  local function finish(result)
    if kill_timer then
      kill_timer:stop()
      kill_timer:close()
    end
    ---@type string|nil, string|nil
    local body, status = (result.stdout or ""):match("^(.*)\n(%d%d%d)$")
    local exit = result.code
    if exit == 0 and result.signal ~= 0 then exit = 128 + result.signal end
    local invalid_response = exit == 0 and not status
    if invalid_response then exit = 1 end
    local response = { status = tonumber(status) or 0, body = body or "", exit = exit }
    if exit ~= 0 then
      local stderr = result.stderr or ""
      local message = stderr ~= "" and stderr
        or (invalid_response and "Invalid HTTP response" or ("curl exited with code " .. exit))
      local err = { message = message, stderr = stderr, exit = exit }
      if not opts.on_error then error(message, 0) end
      opts.on_error(err)
    elseif opts.callback then
      opts.callback(response)
    end
    return response
  end

  local job = vim.system(args, { stdin = opts.body, timeout = timeout }, opts.callback and finish or nil)
  if opts.callback then
    kill_timer = assert(vim.uv.new_timer())
    kill_timer:start(timeout + 1000, 0, function()
      if not job:is_closing() then job:kill(9) end
    end)
    return job
  end
  return finish(job:wait(timeout))
end

---@param url string
---@param opts? avante.utils.curl.Options
---@return avante.utils.curl.Response|vim.SystemObj
function M.get(url, opts) return request("GET", url, opts) end

---@param url string
---@param opts? avante.utils.curl.Options
---@return avante.utils.curl.Response|vim.SystemObj
function M.post(url, opts) return request("POST", url, opts) end

return M
