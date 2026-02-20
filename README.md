# Ollama Copilot
<img src="assets/demoV2.gif" width="900"  alt="Demo GIF">


## Overview
### Copilot-like Tab Completion for NeoVim
Ollama Copilot allows users to integrate their Ollama code completion models into Neovim, giving GitHub Copilot-like tab completions.  
  
Offers **Suggestion Streaming** which will stream the completions into your editor as they are generated from the model.

### Optimizations:
- [x] Debouncing for subsequent completion requests to avoid overflows of Ollama requests which lead to CPU over-utilization.
- [x] Full control over triggers, using textChange events instead of Neovim client requests.
### Features
- [x] Language server which can provide code completions from an Ollama model
- [x] Ghost text completions which can be inserted into the editor
- [x] Streamed ghost text completions which populate in real-time


## Install
### Requires
To use Ollama-Copilot, you need to have Ollama installed [github.com/ollama/ollama](https://github.com/ollama/ollama):  
```bash
curl -fsSL https://ollama.com/install.sh | sh
```
Also, the language server runs on Python, and requires two libraries (Can also be found in python/requirements.txt)
```bash
pip install pygls ollama
```
Make sure you have the model you want to use installed, a catalog can be found here: [ollama.com/library](https://ollama.com/library?q=code)
```
# To view your available models:
ollama ls

# To pull a new model
ollama pull <Model name>
```
### Using a plugin manager
Lazy:
```lua
-- Default configuration
{"Jacob411/Ollama-Copilot", opts={}}
```
```lua
-- Custom configuration (defaults shown)
{
  'jacob411/Ollama-Copilot',
  opts = {
    -- Prefer base code models for autocomplete, not *-instruct chat variants.
    model_name = "qwen2.5-coder:3b",
    ollama_url = "http://localhost:11434", -- URL for Ollama server, Leave blank to use default local instance.
    stream_suggestion = false,
    python_command = "python3",
    filetypes = {'python', 'lua','vim', "markdown"},
    capabilities = nil, -- LSP capabilities, auto-detected if not provided
    ollama_model_opts = {
        temperature = 0.1, -- keep low entropy for stable tab completion
        top_p = 0.9,
        num_predict = 128, -- 64-256 is usually best for autocomplete
        num_ctx = 8192,
        fim_enabled = true, -- include prefix + suffix (Fill-in-the-middle)
        fim_mode = "auto", -- "auto" | "template" | "manual" | "off"
        context_lines_before = 80,
        context_lines_after = 40,
        max_prefix_chars = 8000,
        max_suffix_chars = 3000,
        stop = { "<|im_start|>", "<|im_end|>", "<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>", "```" },
        -- Internal payload/response logging (or set OLLAMA_COPILOT_DEBUG=1).
        -- debug = true,
        -- debug_log_file = "/tmp/ollama-copilot-debug.log",
    },
    keymaps = {
        suggestion = '<leader>os',
        reject = '<leader>or',
        insert_accept = '<Tab>',
    },
}
},
```
For more Ollama customization, see [github.com/ollama/ollama/blob/main/docs/modelfile.md](https://github.com/ollama/ollama/blob/main/docs/modelfile.md)

### LSP Capabilities Configuration

The plugin automatically detects and configures LSP capabilities for optimal completion support:

1. **Auto-detection (default)**: If `capabilities` is not specified, the plugin will:
   - Try to use `cmp_nvim_lsp.default_capabilities()` if nvim-cmp is installed
   - Fall back to `vim.lsp.protocol.make_client_capabilities()` if nvim-cmp is not available

2. **Custom capabilities**: You can override the auto-detection by providing your own capabilities:
   ```lua
   opts = {
     capabilities = require('cmp_nvim_lsp').default_capabilities(),
     -- or use custom capabilities
     capabilities = vim.tbl_deep_extend('force',
       vim.lsp.protocol.make_client_capabilities(),
       { your_custom_capability = true }
     )
   }
   ```

This ensures backward compatibility while allowing the plugin to work without requiring nvim-cmp as a dependency.

## Usage
Ollama copilot language server will attach when you enter a buffer and can be viewed using:
```lua
:LspInfo
```
### Recomendations
Prefer base coder models for completion quality (`qwen2.5-coder:*`, `deepseek-coder:*`) and avoid `*-instruct` unless you explicitly want chat-like behavior.  
`3B` models are fast but can be weak/unstable on instruction-heavy files (markdown/docs), so `7B` is often a better default if your machine can handle it.

### Payload Debugging
To inspect exact requests sent to Ollama and raw streamed chunks:
```bash
OLLAMA_COPILOT_DEBUG=1 nvim
```
or set in `ollama_model_opts`:
```lua
debug = true
debug_log_file = "/tmp/ollama-copilot-debug.log"
```

### Minimal Repro Script
Use the included payload test script to verify prompt shape and suffix usage:
```bash
cd ~/path/to/Ollama-Copilot
python3 python/payload_debug_demo.py
```
  
## Contributing
Contributions are welcome! If you have any ideas for new features, improvements, or bug fixes, please open an issue or submit a pull request.

I am hopeful to add more on the model side as well, as I am interested in finetuning the models and implementing RAG techniques, moving outside of using just Ollama.

## License
This project is licensed under the MIT License.
