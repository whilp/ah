-- bootstrap: fetch cosmic for build tools
-- this file is executed directly by lua to bootstrap the build

local version = "2026-02-06-c7537ca"
local sha = "19f8991a9254f093b83546ecdf780c073b039600f060ab93f6ce78f1ef020bd8"
local url = "https://github.com/whilp/cosmic/releases/download/" .. version .. "/cosmic-lua"

local function main(args)
  local platform = args[1]
  local output = args[2]

  if not platform or not output then
    io.stderr:write("usage: lua version.lua <platform> <output>\n")
    os.exit(1)
  end

  -- check if already downloaded
  local f = io.open(output, "rb")
  if f then
    f:close()
    return
  end

  io.stderr:write("==> fetching cosmic " .. version .. "\n")

  -- use curl to download
  local tmp = output .. ".tmp"
  local cmd = string.format("curl -fsSL -o %q %q", tmp, url)
  local ok = os.execute(cmd)
  if not ok then
    io.stderr:write("error: failed to download cosmic\n")
    os.exit(1)
  end

  -- verify sha256
  local handle = io.popen(string.format("sha256sum %q | cut -d' ' -f1", tmp))
  if handle then
    local actual = handle:read("*l")
    handle:close()
    if actual ~= sha then
      os.remove(tmp)
      io.stderr:write("error: sha256 mismatch\n")
      io.stderr:write("  expected: " .. sha .. "\n")
      io.stderr:write("  actual:   " .. actual .. "\n")
      os.exit(1)
    end
  end

  os.rename(tmp, output)
end

main(arg)
