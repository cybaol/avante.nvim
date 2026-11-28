describe("OpenAI subscription model selection", function()
  it("uses Rig's ChatGPT catalog without an API key or HTTP request", function()
    local RigClient = require("avante.libs.rig_client")
    local models = { { id = "gpt-6.1-sol", name = "gpt-6.1-sol" } }
    local list = stub(RigClient, "chatgpt_models").returns(models)
    local result = require("avante.providers.openai").list_models({
      auth_type = "subscription",
      _model_list_cache = { { id = "stale-api-model" } },
      parse_api_key = function() error("must not read an API key") end,
    })
    list:revert()
    assert.same(models, result)
    assert.stub(list).was_called(1)
  end)
end)

describe("OpenAI model query errors", function()
  local stub = require("luassert.stub")
  local Curl = require("avante.utils.curl")
  local Utils = require("avante.utils")
  local request, info, report

  before_each(function()
    request = stub(Curl, "get")
    info = stub(Utils, "info")
    report = stub(Utils, "error")
  end)

  after_each(function()
    request:revert()
    info:revert()
    report:revert()
  end)

  it("includes HTTP status for empty and nonempty error responses", function()
    for _, response in ipairs({ { status = 302, body = "" }, { status = 403, body = "forbidden" } }) do
      request.returns(response)
      local models = require("avante.providers.openai").list_models({
        endpoint = "https://api.example.com/v1",
        api_key_name = "",
      })
      assert.same({}, models)
      assert
        .stub(report)
        .was_called_with(string.format("Failed to fetch OpenAI-compatible models (HTTP %d): %s", response.status, response.body))
    end
  end)
end)
