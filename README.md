# SAIA CLI

A simple, minimal-dependency Bash CLI interface for the [Scalable Artificial Intelligence (SAIA) API](https://docs.hpc.gwdg.de/services/ai-services/saia/index.html).

This client provides a minimalistic way to interact with all SAIA service and inference endpoints directly from your terminal, making it ideal for quick testing, shell pipelines, and lightweight automation.

## Features

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

## Usage

Run the script without arguments to see the help menu:
```bash
./saia.sh
```

### Examples

**List available models:**
```bash
./saia.sh models
```

**Check your remaining quota:**
```bash
./saia.sh limits
```

**Note on rate limits:** All SAIA models share a single user account quota pool (30 req/min, 200 req/hr, 1,000 req/day, 3,000 req/month). Running `./saia.sh limits` sends a minimal 1-token request payload so Kong returns your actual inference quota instead of an un-routed fallback default. *Note: Running this probe consumes 1 request attempt from your API quota.*

**Convert a PDF to Markdown (via Docling):**
```bash
./saia.sh convert document.pdf > document.md
```

**Chat with an LLM (Simple):**
```bash
./saia.sh chat "How do I refactor this Bash script?"
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
