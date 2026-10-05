--- Generate AI images from Lua with no API key and no account.
--
--   local veida = require("veida")
--   local img, err = veida.generate("matte black ceramic mug on pale oak, soft window light")
--   if img then print(img.url) else print(err.reason, err.message) end
--
-- Calls the anonymous tier of https://veida.ai, which meters its free
-- allowance against a client id this module invents rather than an account
-- you register: 4 credits per id, 4 per image, 30 per IP per day. Free output
-- is 1K and watermarked.
--
-- Failures come back as nil plus a table { reason = ..., message = ... } where
-- reason is "quota" (wait, or sign in), "rejected" (reword the prompt),
-- "timeout" (retry) or "other".

local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local json = require("dkjson")

local M = {
  _VERSION = "0.1.0",
  base_url = "https://veida.ai",
  ANON_GRANT = 4,
  COST_TEXT_TO_IMAGE = 4,
  IP_DAILY_CEILING = 30,
  MODEL = "veida-image-v1",
}

local RATIOS = { ["1:1"] = true, ["16:9"] = true, ["9:16"] = true, ["4:3"] = true, ["3:4"] = true }

local function fail(reason, message)
  return nil, { reason = reason, message = "veida: " .. message }
end

local function anon_id()
  local t = { "lua-" }
  for _ = 1, 8 do t[#t + 1] = string.format("%02x", math.random(0, 255)) end
  return table.concat(t)
end

local function urlencode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function request(url, id, body)
  local out = {}
  local headers = { ["x-anon-id"] = id, ["User-Agent"] = "veida-lua/0.1.0" }
  if body then
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#body)
  end
  local ok, code = https.request({
    url = url,
    method = body and "POST" or "GET",
    headers = headers,
    source = body and ltn12.source.string(body) or nil,
    sink = ltn12.sink.table(out),
  })
  if not ok then return fail("other", tostring(code)) end
  local env = json.decode(table.concat(out))
  if type(env) ~= "table" then return fail("other", "unexpected response") end
  if env.code ~= 0 then return fail("other", env.message or "request refused") end
  return env.data or {}
end

--- Interpret the submit response. The quota wall answers 200 with code 0, so
-- it is recognised by a field. Returns the task id, or nil, err.
function M.parse_submit(d)
  if d.wall then
    if d.reason == "anon_ip_daily" then
      return fail("quota", "this machine has used its " .. M.IP_DAILY_CEILING .. " free credits for today; sign in at https://veida.ai/pricing")
    end
    return fail("quota", "free allowance spent; sign in at https://veida.ai/pricing")
  end
  if not d.id or d.id == "" then return fail("other", "the service returned no task id") end
  return d.id
end

--- Interpret one poll. Status is not monotonic, so only a terminal failure
-- ends the wait. Returns an image, false (keep waiting), or nil, err.
function M.parse_poll(p)
  if p.images and p.images[1] then
    return { url = p.images[1], watermarked = (p.watermarked and p.watermarked[1]) == true }
  end
  local s = tostring(p.status or ""):lower()
  if s == "failed" or s == "error" then return fail("rejected", "prompt refused by the content filter; reword it") end
  return false
end

--- Turn a prompt into an image.
-- opts: aspect_ratio ("1:1", "16:9", "9:16", "4:3", "3:4"), poll_seconds, timeout_seconds.
-- Returns { url = ..., watermarked = ... } or nil, err.
function M.generate(prompt, opts)
  opts = opts or {}
  if not prompt or prompt:match("^%s*$") then return fail("other", "prompt is required") end
  local ratio = opts.aspect_ratio or "1:1"
  if not RATIOS[ratio] then return fail("other", "aspect_ratio must be one of 1:1, 16:9, 9:16, 4:3, 3:4") end
  local id = anon_id()
  local deadline = socket.gettime() + (opts.timeout_seconds or 240)

  local d, err = request(M.base_url .. "/api/ai/generate", id, json.encode({
    provider = "kie", mediaType = "image", model = M.MODEL,
    scene = "text-to-image", prompt = prompt,
    options = { aspect_ratio = ratio },
  }))
  if not d then return nil, err end
  local task, terr = M.parse_submit(d)
  if not task then return nil, terr end

  local query = M.base_url .. "/api/ai/anon-query?taskId=" .. urlencode(task) .. "&provider=kie&mediaType=image"
  while socket.gettime() < deadline do
    socket.sleep(opts.poll_seconds or 4)
    local p = request(query, id) -- a dropped poll is not a failed job
    if p then
      local img, perr = M.parse_poll(p)
      if img then return img end
      if img == nil then return nil, perr end
    end
  end
  return fail("timeout", "still queued when the deadline passed")
end

math.randomseed(os.time() + math.floor(socket.gettime() * 1000) % 100000)

return M
