# pptx

Extract and view images from PowerPoint (.pptx) files.

## Usage

Invoke this skill when asked to read, view, or analyze a `.pptx` file.

## Steps

1. Call `extract_pptx` with the path to the `.pptx` file and an output directory.
2. The tool unzips the file, copies slide media (images) to the output directory, and downsamples large images to reduce payload size.
3. Read the returned image paths using the `read` tool to view the slide content.

## Notes

- Images wider than 1024px are resampled to 1024px wide and converted to JPEG (quality 80) using `sips` (macOS). On non-macOS systems where `sips` is unavailable, images are served at original size.
- The output directory is created if it does not exist.
- Only slide media files (`ppt/media/*`) are extracted — not fonts, themes, or other assets.
