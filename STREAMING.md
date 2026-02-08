## The `fetch.Fetch` Buffering Problem

### What happens now

`api.tl:166-171` does a synchronous, fully-buffered HTTP call:

```teal
result = fetch.Fetch(API_URL, {
  method = "POST",
  headers = auth_headers,
  body = body,
  maxresponse = 10 * 1024 * 1024,
} as fetch.Opts)
```

`fetch.Fetch` blocks until the **entire response body** is downloaded. Then `api.tl:228` parses SSE events from the already-complete string:

```teal
for line in result.body:gmatch("[^\r\n]+") do
  local kind, data = parse_sse_line(line)
  if kind == "data" and data ~= "[DONE]" then
    callback(event)  -- fires, but only after full body is in memory
  end
end
```

The streaming callback at `init.tl` (which writes text deltas to the terminal) fires during this loop, but by then the entire generation is already finished. The user sees nothing for the full duration of Claude's generation, then all text appears at once.

### Concrete impact

For a response that takes Claude 10 seconds to generate:
- **Current behavior:** 10 seconds of nothing, then all text appears instantly
- **Expected behavior:** text starts appearing within ~200ms, streams token-by-token over 10 seconds

This is by far the biggest contributor to perceived slowness. The retry/backoff fixes help with error recovery, but the buffered fetch dominates normal operation.

### What `cosmic.fetch` needs

A streaming fetch API that yields chunks as they arrive. Something like:

```teal
-- Option A: callback-per-chunk
fetch.Stream(url, opts, function(chunk: string)
  -- called as each chunk arrives from the network
end): fetch.Result

-- Option B: iterator
for chunk in fetch.StreamChunks(url, opts) do
  -- process chunk as it arrives
end
```

The key requirement: the callback/iterator must fire as TCP data arrives, not after the full response is buffered.

### What changes in `api.tl` once streaming fetch exists

The `stream()` function currently has two phases that need to merge into one:

1. **Phase 1** (line 165-212): fetch the entire response with retry loop
2. **Phase 2** (line 228-280): parse SSE events from buffered body

With a streaming fetch, SSE parsing moves inside the fetch callback. The partial-line buffering logic would look something like:

```teal
local line_buffer = ""

streaming_fetch(API_URL, opts, function(chunk: string)
  line_buffer = line_buffer .. chunk
  while true do
    local newline_pos = line_buffer:find("\n")
    if not newline_pos then break end
    local line = line_buffer:sub(1, newline_pos - 1):gsub("\r$", "")
    line_buffer = line_buffer:sub(newline_pos + 1)

    local kind, data = parse_sse_line(line)
    if kind == "data" and data ~= "[DONE]" then
      local event = json.decode(data)
      if event then callback(event) end
    end
  end
end)
```

Retry logic gets trickier with streaming - you can detect failure on the initial response status, but mid-stream failures (connection drops) need different handling. pi-mono handles this by catching errors from the async iterator and retrying the full request for empty streams (their "empty stream retry" logic in `google-gemini-cli.ts:785-820`).

### How pi-mono does it

`pi-mono/packages/ai/src/providers/anthropic.ts:228`:

```typescript
const anthropicStream = client.messages.stream({ ...params, stream: true }, { signal: options?.signal });
```

This returns an async iterator that yields SSE events in real time. They iterate over it with `for await`, so text appears token-by-token as Claude generates. The Anthropic SDK handles all the chunked HTTP reading internally.
