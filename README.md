# SAIA CLI

A simple, minimal-dependency Bash CLI interface for the [Scalable Artificial Intelligence (SAIA) API](https://docs.hpc.gwdg.de/services/ai-services/saia/index.html).

This client provides a minimalistic way to interact with all SAIA service and inference endpoints directly from your terminal, making it ideal for quick testing, shell pipelines, and lightweight automation.

## Features

- **Multi-Endpoint Support**: Effortlessly switch between Academic Cloud (default), GWDG SAIA, or any compatible custom gateway/proxy.
- **Full API Coverage**: Support for models, rate limits, Docling document conversion, embeddings, and audio processing.
- **Inference Support**: Single-shot chat completions, text generation, and image generation/editing.
- **RAG Ready**: Direct support for querying Arcanas.
- **Pipeline Friendly**: Supports reading prompts from `stdin`.
- **Minimal Dependencies**: Requires only common system tools: `curl`, `jq`, and `base64`.

## Installation

Because this is a single-file script, you do not need to clone the entire repository. You can download it directly into your local `bin` directory and make it executable.

**Quick Install (Recommended):**
```bash
# 1. Ensure the local bin directory exists
mkdir -p ~/.local/bin

# 2. Download the script directly to your path
curl -o ~/.local/bin/saia https://raw.githubusercontent.com/e-kotov/gwdg-saia-client/main/saia.sh

# 3. Make it executable
chmod +x ~/.local/bin/saia
```
*(Note: Ensure that `~/.local/bin` is in your `$PATH` environment variable).*

## Authentication

The script requires a SAIA API key. You can provide it in three ways:

1. **Environment Variable**:
   ```bash
   export SAIA_API_KEY='your_key_here'
   ```
2. **.env File**: Create a `.env` file in the working directory:
   ```bash
   SAIA_API_KEY=your_key_here
   ```
3. **macOS Keychain**: If on macOS, `saia` automatically attempts to retrieve `saia_api_key` from your system keychain if `SAIA_API_KEY` is not set.

## Endpoint Selection

The CLI provides a single `-e` / `--endpoint` selector that accepts either a built-in endpoint name or an absolute HTTP(S) API root URL:

| Endpoint | Base URL | Default |
| --- | --- | --- |
| `academiccloud` | `https://chat-ai.academiccloud.de/v1` | Yes |
| `gwdg` | `https://saia.gwdg.de/v1` | No |
| Custom URL | `http://...` or `https://...` | No |

For a custom endpoint, provide its exact API root, including a version path when
that service requires one, for example `https://gateway.example.edu/v1`. The CLI
never guesses or appends `/v1`.

### Precedence

The active endpoint is selected in this order:
1. `-e` / `--endpoint` CLI option (`saia -e gwdg models` or `saia limits -e gwdg`)
2. Inherited `SAIA_ENDPOINT` environment variable (`export SAIA_ENDPOINT=gwdg`)
3. `SAIA_ENDPOINT` in the project `.env` file (`SAIA_ENDPOINT=gwdg`)
4. Explicit legacy `BASE_URL` fallback
5. Built-in default (`academiccloud`)

## Usage

Run the script without arguments to see the help menu:
```bash
./saia.sh
```

### Examples

**List available models:**
```bash
./saia.sh models

# Query GWDG endpoint
./saia.sh -e gwdg models

# Query custom gateway
./saia.sh -e https://gateway.example.edu/v1 models
```

**Check your remaining quota:**
```bash
./saia.sh limits
./saia.sh -e gwdg limits
```

**Note on rate limits:** Running `./saia.sh limits` sends a minimal 1-token request payload so Kong returns your actual inference quota instead of an un-routed fallback default. Reset times returned by the API headers are displayed alongside their corresponding quota window (e.g. minute rollover, or specific exhausted window). Reset times include both a compact duration and the local date, time, and timezone. *Note: Running this probe consumes 1 request attempt from your API quota.*

**Convert a PDF to Markdown (via Docling):**
```bash
./saia.sh convert document.pdf > document.md
```

**Chat with an LLM (Simple):**
```bash
./saia.sh chat "How do I refactor this Bash script?"

# Chat using GWDG endpoint
./saia.sh -e gwdg chat "How do I refactor this Bash script?"
```

**Chat with an LLM (Custom system prompt + stdin):**
```bash
echo "How do I refactor this Bash script?" | ./saia.sh chat "You are a senior engineer" -
```

**Generate an image:**
```bash
./saia.sh image "A high-tech data center in the clouds"
# Saves to generated_image.png
```

## Dependencies

The script automatically checks for these dependencies on startup:
- `curl`
- `jq`
- `base64`
