local stub = require("luassert.stub")
local Curl = require("avante.utils.curl")

local SECRET = "sk-test-SECRET123"
local URL = "https://api.example.com/v1/models"

describe("avante.utils.curl", function()
  local system, args, options, on_exit, result

  before_each(function()
    result = { code = 0, signal = 0, stdout = "{}\n200", stderr = "" }
    system = stub(vim, "system", function(command, opts, callback)
      args, options, on_exit = command, opts, callback
      return { wait = function() return result end }
    end)
  end)

  after_each(function() system:revert() end)

  it("passes request values unchanged as separate arguments and sends the body through stdin", function()
    local opts = {
      headers = { X_Api_Key = 'Bearer "' .. SECRET .. "\\" },
      auth = 'user:se"cr\\et-' .. SECRET,
      body = '{"key":"' .. SECRET .. '"}',
      proxy = 'http://user:se"cr\\et-' .. SECRET .. "@localhost:8080",
      insecure = true,
      timeout = 1000,
    }
    local original = vim.deepcopy(opts)
    local url = URL .. '?api_key="se\\cret-' .. SECRET
    assert.same({ status = 200, body = "{}", exit = 0 }, Curl.post(url, opts))
    assert.same({
      "curl",
      "--disable",
      "--silent",
      "--show-error",
      "--request",
      "POST",
      "--write-out",
      "\n%{http_code}",
      "--url",
      url,
      "--user",
      opts.auth,
      "--proxy",
      opts.proxy,
      "--header",
      "X-Api-Key: " .. opts.headers.X_Api_Key,
      "--data-binary",
      "@-",
      "--insecure",
      unpack(package.config:sub(1, 1) ~= "\\" and { "--compressed" } or {}),
    }, args)
    assert.equals(opts.body, options.stdin)
    assert.equals(opts.timeout, options.timeout)
    assert.is_true(vim.tbl_contains(args, "--insecure"))
    assert.is_true(vim.tbl_contains(args, "@-"))
    assert.same(original, opts)
  end)

  it("rejects request control characters before starting curl", function()
    for _, control in ipairs({ "\r", "\n", "\0" }) do
      for _, field in ipairs({ "url", "auth", "proxy" }) do
        local url = URL
        local opts = { headers = { Authorization = SECRET } }
        if field == "url" then
          url = URL .. control .. "output = /tmp/injected"
        else
          opts[field] = "user:pass" .. control .. "output = /tmp/injected"
        end
        assert.has_error(function() Curl.get(url, opts) end, "curl request values must not contain NUL, CR or LF")
      end
    end
    assert.stub(system).was_not_called()
  end)

  it("rejects header control characters before starting curl", function()
    for _, control in ipairs({ "\r", "\n", "\0" }) do
      for _, field in ipairs({ "name", "value" }) do
        local name = field == "name" and ("X-Key" .. control .. "X-Injected") or "X-Key"
        local value = field == "value" and (SECRET .. control .. "X-Injected: yes") or SECRET
        assert.has_error(
          function() Curl.get(URL, { headers = { [name] = value }, auth = SECRET }) end,
          "curl header names and values must not contain NUL, CR or LF"
        )
      end
    end
    assert.stub(system).was_not_called()
  end)

  it("sets the default process timeout for async requests", function()
    local opts = { callback = function() end }
    Curl.get(URL, opts)
    local timeout = options.timeout
    on_exit(result)
    assert.equals(30000, timeout)
    assert.is_nil(opts.timeout)
  end)

  it("returns HTTP errors and empty responses without treating them as transport errors", function()
    result.stdout = "unavailable\n503"
    assert.same({ status = 503, body = "unavailable", exit = 0 }, Curl.get(URL))
    result.stdout = "\n204"
    assert.same({ status = 204, body = "", exit = 0 }, Curl.get(URL))
  end)

  it("returns redirects without following them or loading the default curl config", function()
    result.stdout = "moved\n302"
    assert.same({ status = 302, body = "moved", exit = 0 }, Curl.post(URL, { body = "payload" }))
    assert.equals("--disable", args[2])
    assert.is_false(vim.tbl_contains(args, "--location"))
  end)

  it("preserves response bytes including CRLF, NUL and trailing newlines", function()
    local body = "hello\r\nworld\0\n\n"
    result.stdout = body .. "\n200"
    assert.equals(body, Curl.get(URL).body)
    assert.is_falsy(options.text)
  end)

  it("completes async callbacks", function()
    local callback = stub.new()
    Curl.get(URL, { headers = { Authorization = SECRET }, callback = callback })
    on_exit(result)
    assert.stub(callback).was_called_with({ status = 200, body = "{}", exit = 0 })
  end)

  it("reports async transport errors, including termination by a signal", function()
    local on_error = stub.new()
    Curl.get(URL, { headers = { Authorization = SECRET }, callback = function() end, on_error = on_error })
    on_exit({ code = 7, signal = 0, stderr = "connection refused" })
    assert.stub(on_error).was_called_with({ message = "connection refused", stderr = "connection refused", exit = 7 })
    Curl.get(URL, { callback = function() end, on_error = on_error })
    on_exit({ code = 0, signal = 15 })
    assert.equals(143, on_error.calls[2].vals[1].exit)
  end)

  it("raises unhandled transport errors and rejects malformed output", function()
    result = { code = 28, signal = 0, stderr = "request timed out" }
    assert.has_error(function() Curl.get(URL, { headers = { Authorization = SECRET } }) end, "request timed out")
    result = { code = 0, signal = 0, stdout = "invalid" }
    assert.has_error(function() Curl.get(URL) end, "Invalid HTTP response")
    Curl.get(URL, { callback = function() end })
    assert.has_error(function() on_exit({ code = 7, signal = 0, stderr = "curl failed" }) end, "curl failed")
  end)

  it("propagates curl spawn errors", function()
    system.invokes(function() error("curl: Executable not found", 0) end)
    assert.has_error(function() Curl.get(URL, { auth = SECRET }) end, "curl: Executable not found")
  end)

  it("passes a URL starting with a dash as an option value", function()
    local url = "--output=unexpected"
    Curl.get(url)
    for i, arg in ipairs(args) do
      if arg == "--url" then
        assert.equals(url, args[i + 1])
        return
      end
    end
    error("missing --url option")
  end)
end)

it("waits for a real curl process to finish its callback", function()
  local path = vim.fn.tempname()
  local body = "hello\r\nworld\0\n\n"
  local file = assert(io.open(path, "wb"))
  file:write(body)
  file:close()
  local response
  local job = Curl.get("file://" .. path, {
    headers = { X_Test = 'quotes " and slashes \\' },
    callback = function(value) response = value end,
  })
  local ok, err = pcall(job.wait, job, 1000)
  os.remove(path)
  assert.is_true(ok, err)
  assert.same({ status = 0, body = body, exit = 0 }, response)
end)

it("ignores a real curlrc that redirects response output to a file", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir)
  vim.fn.writefile({ "{}" }, dir .. "/body")
  vim.fn.writefile({ 'output = "' .. dir .. '/output"' }, dir .. "/.curlrc")
  local real_system = vim.system
  local system = stub(vim, "system", function(command, opts, callback)
    opts.env = { CURL_HOME = dir }
    return real_system(command, opts, callback)
  end)
  local ok, response = pcall(Curl.get, "file://" .. dir .. "/body")
  system:revert()
  local output_exists = vim.uv.fs_stat(dir .. "/output") ~= nil
  vim.fn.delete(dir, "rf")
  assert.is_true(ok, response)
  assert.is_false(output_exists)
  assert.same({ status = 0, body = "{}\n", exit = 0 }, response)
end)

describe("curl process timeouts", function()
  local system, job, path, ignore_term

  before_each(function()
    job, path, ignore_term = nil, vim.fn.tempname(), false
    local real_system = vim.system
    system = stub(vim, "system", function(_, opts, callback)
      local command = {
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "+lua vim.defer_fn(function() vim.cmd('qa!') end, 10000)",
      }
      if ignore_term then
        command = { "sh", "-c", 'trap "" TERM; printf ready > "$1"; exec sleep 10', "curl-test", path .. ".ready" }
      end
      job = real_system(command, opts, callback)
      return job
    end)
  end)

  after_each(function()
    system:revert()
    if job and vim.uv.kill(job.pid, 0) == 0 then
      job:kill(9)
      job:wait(1000)
    end
    if path then os.remove(path .. ".ready") end
  end)

  it("times out without wait", function()
    local callback, on_error = stub.new(), stub.new()
    Curl.get(URL, { timeout = 50, callback = callback, on_error = on_error })
    assert.is_true(vim.wait(1000, function() return #on_error.calls > 0 end), "request did not time out on its own")
    assert.is_false(vim.uv.kill(job.pid, 0) == 0)
    assert.stub(callback).was_not_called()
    assert.stub(on_error).was_called(1)
    assert.equals(124, on_error.calls[1].vals[1].exit)
  end)

  it("terminates and cleans up before wait returns", function()
    local callback, on_error = stub.new(), stub.new()
    local request = Curl.get(URL, { callback = callback, on_error = on_error })
    local result = request:wait(100)
    assert.equals(124, result.code)
    assert.is_false(vim.uv.kill(job.pid, 0) == 0)
    assert.stub(callback).was_not_called()
    assert.stub(on_error).was_called(1)
    assert.equals(124, on_error.calls[1].vals[1].exit)
  end)

  it("kills an async process that ignores TERM", function()
    if vim.fn.has("win32") == 1 then pending("Ignoring TERM requires POSIX signals") end
    ignore_term = true
    local callback, on_error = stub.new(), stub.new()
    Curl.get(URL, { timeout = 500, callback = callback, on_error = on_error })
    assert.is_true(vim.wait(400, function() return vim.uv.fs_stat(path .. ".ready") ~= nil end, 5))
    assert.is_true(vim.wait(2500, function() return #on_error.calls > 0 end, 5), "process survived the timeout")
    assert.is_false(vim.uv.kill(job.pid, 0) == 0)
    assert.stub(callback).was_not_called()
    assert.stub(on_error).was_called(1)
    assert.equals(124, on_error.calls[1].vals[1].exit)
  end)
end)
