describe("lua_ingress", function()
  it("patches math.randomseed to not be called more than once per worker", function()
    local s = spy.on(ngx, "log")

    math.randomseed(100)
    assert.spy(s).was_called_with(ngx.WARN,
      string.format("ignoring math.randomseed(%d) since PRNG is already seeded for worker %d", 100, ngx.worker.pid()))
  end)
end)

describe("lua_ingress global throttle", function()
  local lua_ingress = require("lua_ingress")
  local global_throttle = require("global_throttle")
  local cjson = require("cjson.safe")

  local CONFIG = {
    listen_ports = { https = "443", ssl_proxy = "442" },
    http_redirect_code = 308,
    global_throttle = {
      memcached = { host = "memc", port = 11211 },
      status_code = 429,
    },
  }

  local function request_vars(global_throttle_value)
    return {
      scheme = "http",
      http_host = "example.com",
      pass_server_port = "80",
      request_uri = "/",
      remote_addr = "10.0.0.1",
      global_throttle = global_throttle_value,
    }
  end

  local function encode(location_config)
    return ngx.encode_base64(cjson.encode(location_config))
  end

  before_each(function()
    lua_ingress.set_config(CONFIG)
  end)

  after_each(function()
    reset_ngx()
  end)

  it("does not throttle when $global_throttle is not set", function()
    local s = spy.on(global_throttle, "throttle")
    ngx.var = request_vars(nil)

    lua_ingress.rewrite()

    assert.spy(s).was_not_called()
    global_throttle.throttle:revert()
  end)

  it("passes the decoded location config with a parsed key", function()
    local s = stub(global_throttle, "throttle")
    ngx.var = request_vars(encode({
      namespace = "ns",
      limit = 5,
      window_size = 120,
      key = "${remote_addr}$http_x_api_client",
      ignored_cidrs = { "192.168.1.1" },
    }))

    lua_ingress.rewrite()

    assert.stub(s).was_called(1)
    local location_config = s.calls[1].vals[2]
    assert.are.same(CONFIG.global_throttle, s.calls[1].vals[1])
    assert.are.same("ns", location_config.namespace)
    assert.are.same(5, location_config.limit)
    assert.are.same(120, location_config.window_size)
    assert.are.same({ "192.168.1.1" }, location_config.ignored_cidrs)
    assert.are.same("remote_addr", location_config.key[1][2])
    assert.are.same("http_x_api_client", location_config.key[2][3])
    global_throttle.throttle:revert()
  end)

  it("does not throttle when $global_throttle cannot be decoded", function()
    local s = stub(global_throttle, "throttle")
    ngx.var = request_vars("not-base64-json")

    lua_ingress.rewrite()

    assert.stub(s).was_not_called()
    global_throttle.throttle:revert()
  end)
end)
