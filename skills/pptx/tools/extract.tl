-- skills/pptx/tools/extract.tl: extract and downsample images from a .pptx file
local child = require("cosmic.child")

local function spawn_cmd(args: {string}): string, integer
  local handle, err = child.spawn(args)
  if not handle then
    return "error: failed to spawn: " .. tostring(err), -1
  end
  local _, stdout, exit_str = handle:read()
  local stdout_str = (stdout as string) or ""
  local exit_code = tonumber(exit_str) as integer or 0
  return stdout_str, exit_code
end

-- Check if a command is available by looking in PATH
local function cmd_available(name: string): boolean
  local _, code = spawn_cmd({"sh", "-c", "command -v " .. name .. " >/dev/null 2>&1"})
  return code == 0
end

-- Get pixel width of an image using sips
local function sips_width(path: string): integer
  local out, code = spawn_cmd({"sips", "-g", "pixelWidth", path})
  if code ~= 0 then
    return 0
  end
  -- output: "      pixelWidth: 1920"
  local w = out:match("pixelWidth:%s*(%d+)")
  return tonumber(w) as integer or 0
end

-- Downsample image to 1024px wide JPEG using sips
-- Returns the new output path (may differ in extension)
local function downsample(src: string, output_dir: string, basename: string): string, string
  -- strip extension and build .jpg output path
  local stem = basename:match("^(.+)%.[^%.]+$") or basename
  local outpath = output_dir .. "/" .. stem .. ".jpg"
  local sips_args: {string} = {"sips", "--resampleWidth", "1024", "-s", "format", "jpeg", "-s", "formatOptions", "80", src, "--out", outpath}
  local out, code = spawn_cmd(sips_args)
  if code ~= 0 then
    return src, "sips downsample failed: " .. out
  end
  -- remove original if it differs from output
  if src ~= outpath then
    os.remove(src)
  end
  return outpath, nil
end

return {
  name = "extract_pptx",
  description = "Extract slide media images from a .pptx file. Downsamples images wider than 1024px to JPEG using sips (macOS). Returns list of extracted image paths.",
  input_schema = {
    type = "object",
    properties = {
      pptx_path = {type = "string", description = "Path to the .pptx file"},
      output_dir = {type = "string", description = "Directory to write extracted images into (created if needed)"},
    },
    required = {"pptx_path", "output_dir"},
  },
  execute = function(input: {string: any}): string, boolean, any
    local pptx_path = input.pptx_path as string
    local output_dir = input.output_dir as string

    if not pptx_path or pptx_path == "" then
      return "error: pptx_path is required", true
    end
    if not output_dir or output_dir == "" then
      return "error: output_dir is required", true
    end

    -- create output dir
    local _, mkcode = spawn_cmd({"mkdir", "-p", output_dir})
    if mkcode ~= 0 then
      return "error: failed to create output_dir: " .. output_dir, true
    end

    -- create temp dir for unzip
    local tmpout, tmpcode = spawn_cmd({"mktemp", "-d"})
    if tmpcode ~= 0 then
      return "error: failed to create temp dir", true
    end
    local tmp_dir = tmpout:gsub("%s+$", "")

    -- unzip ppt/media/* from the pptx into tmp_dir
    local unzip_out, unzip_code = spawn_cmd({"unzip", "-o", pptx_path, "ppt/media/*", "-d", tmp_dir})
    if unzip_code ~= 0 then
      spawn_cmd({"rm", "-rf", tmp_dir})
      return "error: unzip failed: " .. unzip_out, true
    end

    -- list files in tmp_dir/ppt/media/
    local media_dir = tmp_dir .. "/ppt/media"
    local ls_out, ls_code = spawn_cmd({"sh", "-c", "ls -1 " .. media_dir .. " 2>/dev/null"})
    if ls_code ~= 0 or ls_out:gsub("%s+", "") == "" then
      spawn_cmd({"rm", "-rf", tmp_dir})
      return "no media files found in pptx", false
    end

    local have_sips = cmd_available("sips")
    local images: {string} = {}
    local notes: {string} = {}

    for basename in ls_out:gmatch("[^\n]+") do
      if basename ~= "" then
        local src = media_dir .. "/" .. basename
        local dst = output_dir .. "/" .. basename
        -- copy to output dir
        local _, cpcode = spawn_cmd({"cp", src, dst})
        if cpcode ~= 0 then
          notes[#notes + 1] = "warning: failed to copy " .. basename
        else
          -- downsample if image is wide and sips is available
          local ext = basename:match("%.([^%.]+)$") or ""
          local is_image = ext == "png" or ext == "jpg" or ext == "jpeg"
          if is_image and have_sips then
            local width = sips_width(dst)
            if width > 1024 then
              local newpath, ds_err = downsample(dst, output_dir, basename)
              if ds_err then
                notes[#notes + 1] = "warning: " .. ds_err .. " (keeping original)"
                images[#images + 1] = dst
              else
                images[#images + 1] = newpath
              end
            else
              images[#images + 1] = dst
            end
          else
            images[#images + 1] = dst
          end
        end
      end
    end

    -- cleanup temp dir
    spawn_cmd({"rm", "-rf", tmp_dir})

    if not have_sips then
      notes[#notes + 1] = "sips not available: images served at original size"
    end

    local result_parts: {string} = {}
    result_parts[#result_parts + 1] = "extracted " .. tostring(#images) .. " file(s) to " .. output_dir
    for _, img in ipairs(images) do
      result_parts[#result_parts + 1] = img
    end
    if #notes > 0 then
      result_parts[#result_parts + 1] = table.concat(notes, "\n")
    end

    return table.concat(result_parts, "\n"), false, {images = images, output_dir = output_dir}
  end,
}
