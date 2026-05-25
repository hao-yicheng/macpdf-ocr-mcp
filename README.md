# macpdf-ocr-mcp

`macpdf-ocr-mcp` is a macOS-native, PDFKit-first stdio MCP server with Apple Vision OCR fallback for scanned or image-heavy PDF pages.

It is designed for local LLM workflows: extract useful text first, add compact images only when they help, and keep large documents batched.

The project is tested with Codex, but it is not Codex-specific. It should work with MCP clients that support local stdio servers, including Claude Desktop, Claude Code, and Gemini CLI. Client-specific setup is intentionally left to each client or AI assistant.

---

## 📊 Light Benchmark

Light local A/B test using Codex CLI with `gpt-5.5`: across three PDF types, MCP preprocessing cut output/reasoning tokens by roughly half or more in all groups, reduced runtime by about one-third to one-half, and cut input tokens by over half on the image-heavy PDF. Mixed-PDF input was approximately unchanged.

| PDF type | Input tokens | Output tokens | Reasoning tokens | Runtime |
|---|---:|---:|---:|---:|
| Image-heavy | -55% | -73% | -92% | -34% |
| Mixed | ~ | -58% | -87% | -53% |
| Text-heavy | -24% | -47% | -63% | -56% |

`~` means approximately unchanged. Results depend on PDF structure, prompt shape, and whether image previews are included in tool output.

---

## ✅ Requirements

- macOS 13 or newer
- Xcode or Apple Command Line Tools with Swift 6.3 or newer
- An MCP client that supports local stdio servers

The implementation uses Apple-native frameworks only: `PDFKit`, `Vision`, `CoreGraphics`, and `AppKit`.

---

## 🛠️ Build

From the project root:

```bash
swift build -c release
```

The release executable is created at:

```bash
.build/release/macpdf-ocr-mcp
```

---

## 🚀 Installation

### Codex

Codex is the currently tested client.

```bash
codex mcp add macpdf-ocr-mcp -- "$(pwd)/.build/release/macpdf-ocr-mcp" mcp-stdio
```

Restart Codex or open a new Codex session after registration so the MCP server list is reloaded.

### Others

Other MCP clients can use the same executable with stdio transport. Point the client at:

```bash
<project-root>/.build/release/macpdf-ocr-mcp mcp-stdio
```

This should work with clients such as Claude Desktop, Claude Code, and Gemini CLI when they are configured for local stdio MCP servers.

---

## ⚙️ Runtime Behavior

- `PDFKit` is preferred when a PDF has a usable text layer.
- `Vision` OCR is used for scanned pages or when OCR is explicitly requested.
- `hybrid` mode uses OCR only when it materially improves missing text extraction.
- Large reads should use batching instead of returning a full document in one response.
- Region boxes use normalized top-left coordinates: `[left, top, width, height]`.

---

## 🔧 MCP Tools

- `pdf_read`

  - First-pass PDF reading. It returns page-grouped text, optional preview image paths, coarse regions, and continuation metadata for batched reads.

  - <details>
    <summary>Arguments and MCP examples</summary>

    > Required:
    >
    > - `file`: PDF path
    > - `pages`: `all`, a single page such as `12`, or a range such as `12-20`
    >
    > Optional:
    >
    > - `mode`
    >   - `balanced` (default): PDFKit/OCR page text + compressed page image (`scale=5`, `1200px`)
    >   - `text_only`: PDFKit/OCR page text + text regions
    >   - `image_only`: compressed page image only (`scale=5`, `1200px`)
    >   - `text_focus`: PDFKit/OCR page text + smaller page image (`scale=5`, `1080px`)
    >   - `image_focus`: PDFKit/OCR page text + larger page image (`scale=5`, `1380px`)
    > - `engine`
    >   - `auto` (default): PDFKit if text exists, otherwise Vision OCR
    >   - `pdfkit`: PDFKit text extraction only
    >   - `ocr`: Vision OCR only
    >   - `hybrid`: like `auto`; reserved for stricter PDFKit+OCR merging
    > - `batch_size`: `4` by default
    > - `image_scale`: `5` by default; `1-2=512px`, `3-4=768px`, `5-6=1200px`, `7-8=1600px`, `9-10=2200px`

    ```json
    {
      "file": "/path/to/document.pdf",
      "pages": "1-3"
    }

    {
      "file": "/path/to/document.pdf",
      "pages": "1-10",
      "mode": "balanced",
      "engine": "auto",
      "batch_size": 5,
      "image_scale": 6
    }
    ```

    </details>

- `pdf_focus`

  - Second-pass detail reading for one normalized page region. It returns local text, an optional cropped image path, and local region hints.

  - <details>
    <summary>Arguments and MCP examples</summary>

    > Required:
    >
    > - `file`: PDF path
    > - `page`: 1-based page number
    > - `bbox_norm`: normalized top-left-origin box `[left, top, width, height]`
    >
    > Optional:
    >
    > - `mode`
    >   - `balanced` (default): PDFKit/OCR region text + compressed region image (`scale=7`, `1600px`)
    >   - `text_only`: PDFKit/OCR region text only
    >   - `image_only`: compressed region image only (`scale=7`, `1600px`)
    >   - `text_focus`: PDFKit/OCR region text + compressed region image (`scale=7`, `1600px`)
    >   - `image_focus`: PDFKit/OCR region text + larger region image (`scale=7`, `2000px`)
    > - `engine`
    >   - `auto` (default): PDFKit if region text exists, otherwise Vision OCR
    >   - `pdfkit`: PDFKit text extraction only
    >   - `ocr`: Vision OCR only
    >   - `hybrid`: like `auto`; reserved for stricter PDFKit+OCR merging
    > - `image_scale`: `7` by default; `1-6=1200px`, `7-8=1600px`, `9-10=2200px`

    ```json
    {
      "file": "/path/to/document.pdf",
      "page": 4,
      "bbox_norm": [0.10, 0.20, 0.70, 0.25]
    }

    {
      "file": "/path/to/document.pdf",
      "page": 4,
      "bbox_norm": [0.10, 0.20, 0.70, 0.25],
      "mode": "balanced",
      "engine": "auto",
      "image_scale": 7
    }
    ```

    </details>

- `save_region`

  - Saves a selected region from a PDF page or image to a local file.

  - <details>
    <summary>Arguments and MCP examples</summary>

    > Required:
    >
    > - `source_type`: `pdf` or `image`
    > - `source_path`: source PDF or image path
    > - `output_path`: destination image path
    > - `bbox_norm`: normalized top-left-origin box `[left, top, width, height]`
    >
    > Additional PDF arguments:
    >
    > - `page`: required when `source_type=pdf`
    > - `short_side_px`: `1600px` by default

    ```json
    {
      "source_type": "pdf",
      "source_path": "/path/to/document.pdf",
      "page": 4,
      "short_side_px": 1600,
      "output_path": "/tmp/region.png",
      "bbox_norm": [0.10, 0.20, 0.70, 0.25]
    }

    {
      "source_type": "image",
      "source_path": "/path/to/image.png",
      "output_path": "/tmp/region.png",
      "bbox_norm": [0.10, 0.20, 0.70, 0.25]
    }
    ```

    </details>

- `ocr_detect_regions`

  - Runs Vision OCR on an image and returns OCR lines, normalized boxes, and grouped candidate regions.

  - <details>
    <summary>Arguments and MCP examples</summary>

    > Required:
    >
    > - `image`: image path
    >
    > Optional:
    >
    > - `bbox_norm`: OCR only this normalized image region

    ```json
    {
      "image": "/path/to/image.png"
    }

    {
      "image": "/path/to/image.png",
      "bbox_norm": [0.10, 0.20, 0.70, 0.25]
    }
    ```

    </details>

Generated preview and focus images are written under `.tmp/runtime/`. That directory is a local runtime artifact and should not be committed.

<details>
<summary>Local CLI debugging</summary>

The executable can also be called directly for local checks. MCP clients normally call tools through the protocol, not through these shell commands.

```bash
.build/release/macpdf-ocr-mcp pdf-read /path/to/document.pdf 1-3
.build/release/macpdf-ocr-mcp pdf-focus /path/to/document.pdf 4 0.10 0.20 0.70 0.25 balanced auto 7
.build/release/macpdf-ocr-mcp save-region pdf /path/to/document.pdf 4 1600 /tmp/region.png 0.10 0.20 0.70 0.25
.build/release/macpdf-ocr-mcp ocr-detect-regions /path/to/image.png
```

</details>

---

## 📦 Distribution

The simplest distribution path is source-first:

```bash
git clone <repo-url>
cd macpdf-ocr-mcp
swift build -c release
codex mcp add macpdf-ocr-mcp -- "$(pwd)/.build/release/macpdf-ocr-mcp" mcp-stdio
```

Prebuilt GitHub Release binaries can be added later once the MCP interface is stable.

---

## 🔗 Acknowledgements & Resources

This project is built with Apple-native frameworks and integrates with MCP-compatible clients.

| Project / Service | Category | Link & Purpose |
| :--- | :--- | :--- |
| Swift | Language | [![Swift](https://img.shields.io/badge/Swift-Official-orange?logo=swift)](https://developer.apple.com/swift/) |
| PDFKit | Apple Framework | [![PDFKit](https://img.shields.io/badge/Apple-PDFKit-black?logo=apple)](https://developer.apple.com/documentation/pdfkit) |
| VisionKit | Apple Framework | [![VisionKit](https://img.shields.io/badge/Apple-VisionKit-black?logo=apple)](https://developer.apple.com/documentation/visionkit) |
| Model Context Protocol | Protocol | [![MCP](https://img.shields.io/badge/MCP-Protocol-blue)](https://modelcontextprotocol.io/) |
| Codex | MCP Client | [![OpenAI Codex](https://img.shields.io/badge/OpenAI-Codex-black?logo=openai)](https://openai.com/codex/) |
