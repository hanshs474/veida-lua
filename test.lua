package.path = "src/?.lua;" .. package.path
local veida = require("veida")
local function check(ok, what) print((ok and "ok   " or "FAIL ") .. what); if not ok then os.exit(1) end end
local _, e = veida.parse_submit({ wall = true, reason = "anon_ip_daily" }); check(e and e.reason == "quota", "wall is quota")
check(veida.parse_submit({ id = "t1" }) == "t1", "task id")
check(veida.parse_poll({ status = "processing" }) == false, "still running")
local n, r = veida.parse_poll({ status = "failed" }); check(n == nil and r.reason == "rejected", "failed is rejected")
check(veida.parse_poll({ images = { "u" }, watermarked = { true } }).watermarked, "watermark flag")
if arg[1] == "live" then
  local img, err = veida.generate("a paper boat on a calm lake at sunrise, soft light", { aspect_ratio = "16:9" })
  check(img ~= nil, "live: " .. (img and img.url or (err.reason .. " " .. err.message)))
end
