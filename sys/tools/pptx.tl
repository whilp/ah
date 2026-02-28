-- sys/tools/pptx.tl: extract slides and images from a .pptx file

local function find_sips(): boolean
  local f = io.open("/usr/bin/sips", "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function get_pixel_width(path: string): integer
  local cmd = "/usr/bin/sips -g pixelWidth " .. string.format("%q", path) .. " 2>/dev/null"
  local f = io.popen(cmd)
  if not f then
    return 0
  end
  local out = f:read("*a") as string
  f:close()
  if not out then
    return 0
  end
  local w = out:match("pixelWidth:%s*(%d+)")
  if not w then
    return 0
  end
  return tonumber(w) as integer or 0
end

local function downsample(src: string, dst: string): boolean
  local cmd = string.format(
    "/usr/bin/sips --resampleWidth 1024 -s format jpeg -s formatOptions 80 %q --out %q >/dev/null 2>&1",
    src, dst
  )
  local rc = os.execute(cmd)
  if type(rc) == "boolean" then
    return rc as boolean
  end
  return (rc as integer) == 0
end

local function strip_xml(s: string): string
  -- Remove XML tags and collapse whitespace
  local out = s:gsub("<[^>]+>", " ")
  out = out:gsub("&amp;", "&")
  out = out:gsub("&lt;", "<")
  out = out:gsub("&gt;", ">")
  out = out:gsub("&apos;", "'")
  out = out:gsub("&quot;", '"')
  out = out:gsub("%s+", " ")
  return out:match("^%s*(.-)%s*$") or ""
end

local function read_file(path: string): string
  local f = io.open(path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a") as string
  f:close()
  return content or ""
end

return {
  name = "pptx",
  description = "Extract slides and images from a .pptx file. Downsamples images wider than 1024px to JPEG using sips (macOS only).",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to the .pptx file"},
      output_dir = {type = "string", description = "Directory to write extracted images (optional; a temp dir is used if omitted)"},
    },
    required = {"path"},
  },
  execute = function(input: {string: any}): string, boolean, any
    local file_path = input.path as string
    if not file_path then
      return "error: path is required", true
    end

    if not file_path:match("%.pptx$") then
      return "error: path must end in .pptx", true
    end

    local f = io.open(file_path, "r")
    if not f then
      return "error: file not found: " .. file_path, true
    end
    f:close()

    -- Create temp directory for extraction
    local tmp_f = io.popen("mktemp -d 2>/dev/null")
    if not tmp_f then
      return "error: failed to create temp directory", true
    end
    local tmpdir = (tmp_f:read("*l") as string) or ""
    tmp_f:close()
    if tmpdir == "" then
      return "error: failed to create temp directory", true
    end

    -- Determine output directory
    local output_dir = (input.output_dir as string) or tmpdir .. "/out"
    os.execute("mkdir -p " .. string.format("%q", output_dir))

    -- Unzip the pptx into tmpdir/pptx
    local pptx_extract = tmpdir .. "/pptx"
    os.execute("mkdir -p " .. string.format("%q", pptx_extract))
    local unzip_rc = os.execute(
      string.format("unzip -q %q -d %q 2>/dev/null", file_path, pptx_extract)
    )
    local unzip_ok: boolean
    if type(unzip_rc) == "boolean" then
      unzip_ok = unzip_rc as boolean
    else
      unzip_ok = (unzip_rc as integer) == 0
    end
    if not unzip_ok then
      os.execute("rm -rf " .. string.format("%q", tmpdir))
      return "error: failed to unzip " .. file_path, true
    end

    -- Collect media files
    local media_dir = pptx_extract .. "/ppt/media"
    local images: {string} = {}
    local has_sips = find_sips()

    local media_f = io.popen("ls " .. string.format("%q", media_dir) .. " 2>/dev/null")
    if media_f then
      local media_list = (media_f:read("*a") as string) or ""
      media_f:close()

      for fname in media_list:gmatch("[^\n]+") do
        if fname ~= "" then
          local src = media_dir .. "/" .. fname
          local ext = fname:match("%.([^%.]+)$") or ""
          ext = ext:lower()

          local is_image = (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "webp")

          if is_image and has_sips and (ext == "png" or ext == "jpg" or ext == "jpeg") then
            -- Check width and downsample if needed
            local width = get_pixel_width(src)
            local basename = fname:match("^(.-)%.[^%.]+$") or fname
            local dst = output_dir .. "/" .. basename .. ".jpg"
            if width > 1024 then
              local ok = downsample(src, dst)
              if ok then
                table.insert(images, dst)
              else
                -- Fall back: copy original
                os.execute(string.format("cp %q %q", src, output_dir .. "/" .. fname))
                table.insert(images, output_dir .. "/" .. fname)
              end
            else
              -- Width <= 1024: copy as-is
              os.execute(string.format("cp %q %q", src, output_dir .. "/" .. fname))
              table.insert(images, output_dir .. "/" .. fname)
            end
          else
            -- No sips or non-image: copy as-is
            os.execute(string.format("cp %q %q", src, output_dir .. "/" .. fname))
            if is_image then
              table.insert(images, output_dir .. "/" .. fname)
            end
          end
        end
      end
    end

    -- Extract slide text
    local slides_dir = pptx_extract .. "/ppt/slides"
    local slide_texts: {string} = {}

    local slides_f = io.popen("ls " .. string.format("%q", slides_dir) .. " 2>/dev/null")
    if slides_f then
      local slides_list = (slides_f:read("*a") as string) or ""
      slides_f:close()

      -- Collect slide filenames and sort them
      local slide_files: {string} = {}
      for fname in slides_list:gmatch("[^\n]+") do
        if fname:match("^slide%d+%.xml$") then
          table.insert(slide_files, fname)
        end
      end

      -- Sort by slide number
      table.sort(slide_files, function(a: string, b: string): boolean
        local na = tonumber(a:match("slide(%d+)%.xml")) as integer or 0
        local nb = tonumber(b:match("slide(%d+)%.xml")) as integer or 0
        return na < nb
      end)

      for _, fname in ipairs(slide_files) do
        local xml_path = slides_dir .. "/" .. fname
        local xml = read_file(xml_path)
        if xml ~= "" then
          local text = strip_xml(xml)
          if text ~= "" then
            local slide_num = fname:match("slide(%d+)%.xml") or "?"
            table.insert(slide_texts, "=== Slide " .. slide_num .. " ===\n" .. text)
          end
        end
      end
    end

    -- Clean up temp extract dir
    os.execute("rm -rf " .. string.format("%q", pptx_extract))

    -- Build summary
    local lines: {string} = {}
    table.insert(lines, "output_dir: " .. output_dir)
    table.insert(lines, "images: " .. tostring(#images))
    table.insert(lines, "slides: " .. tostring(#slide_texts))
    if #images > 0 then
      table.insert(lines, "")
      table.insert(lines, "Image files:")
      for _, img in ipairs(images) do
        table.insert(lines, "  " .. img)
      end
    end
    if #slide_texts > 0 then
      table.insert(lines, "")
      table.insert(lines, "Slide text:")
      for _, st in ipairs(slide_texts) do
        table.insert(lines, st)
      end
    end

    local result = table.concat(lines, "\n")
    return result, false, {
      output_dir = output_dir,
      image_count = #images,
      slide_count = #slide_texts,
    }
  end,
}
