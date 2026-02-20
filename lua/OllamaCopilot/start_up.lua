---Ollama Copilot startup orchestration.
---Handles configuration merge, Python runtime resolution, LSP registration, and UI hooks.

local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")
local ghost_text = require("OllamaCopilot.ghost_text")
local ollama_client = require("OllamaCopilot.lsp_client")

local M = {}

---Default plugin configuration.
local default_config = {
  model_name = "deepseek-coder:base",
  ollama_url = "http://localhost:11434",
  stream_suggestion = false,
  python_command = nil,
  auto_manage_python_env = true,
  python_bootstrap_command = "python3",
  python_venv_dir = nil,
  filetypes = { "python", "lua", "vim", "markdown" },
  capabilities = nil,
  ollama_model_opts = {
    num_predict = 128,
    temperature = 0.1,
    top_p = 0.9,
    num_ctx = 8192,
    fim_enabled = true,
    fim_mode = "auto",
    context_lines_before = 80,
    context_lines_after = 40,
    max_prefix_chars = 8000,
    max_suffix_chars = 3000,
    stop = { "<|im_start|>", "<|im_end|>", "<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>", "```" },
  },
  keymaps = {
    suggestion = "<leader>os",
    reject = "<leader>or",
    insert_accept = "<Tab>",
  },
}

local IMPORT_PROBE = "import pygls, ollama"
local enabled = true

---@param msg string
local function notify_error(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.ERROR)
  end)
end

---@param cmd string[]
---@return boolean ok
---@return string output
local function run_system(cmd)
  local output = vim.fn.system(cmd)
  return vim.v.shell_error == 0, output
end

---@param cmd string[]
---@return string output
local function run_command_or_error(cmd)
  local ok, output = run_system(cmd)
  if ok then
    return output
  end

  local rendered = table.concat(cmd, " ")
  error(("Ollama Copilot command failed (%s): %s"):format(rendered, output))
end

---@param python_bin string
---@return boolean ok
---@return string output
local function probe_python_modules(python_bin)
  return run_system({ python_bin, "-c", IMPORT_PROBE })
end

---@return string
local function plugin_root()
  local source = debug.getinfo(1, "S").source
  local path = source:sub(2)
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(path))) .. "/"
  end

  return vim.fn.fnamemodify(path, ":h:h:h") .. "/"
end

---@param config table
---@param root string
---@return string|nil python_bin
---@return string|nil err
local function resolve_python_command(config, root)
  if config.python_command and config.python_command ~= "" then
    local ok, output = probe_python_modules(config.python_command)
    if ok then
      return config.python_command, nil
    end

    return nil, table.concat({
      "Ollama Copilot: provided python_command cannot import required modules.",
      ("python_command: %s"):format(config.python_command),
      "Expected imports: pygls, ollama",
      "Fix by installing dependencies in that interpreter, or remove python_command and enable auto_manage_python_env.",
      output,
    }, "\n")
  end

  if not config.auto_manage_python_env then
    return nil, table.concat({
      "Ollama Copilot: no python runtime configured.",
      "Set python_command explicitly, or enable auto_manage_python_env.",
    }, "\n")
  end

  local venv_dir = config.python_venv_dir
  if not venv_dir or venv_dir == "" then
    venv_dir = table.concat({ vim.fn.stdpath("data"), "ollama-copilot", "venv" }, "/")
  end

  local python_bin = table.concat({ venv_dir, "bin", "python" }, "/")
  local requirements = root .. "python/requirements.txt"

  local ok, err = pcall(function()
    if vim.fn.executable(python_bin) == 0 then
      run_command_or_error({ config.python_bootstrap_command, "-m", "venv", venv_dir })
    end

    local has_modules = probe_python_modules(python_bin)
    if not has_modules then
      run_command_or_error({ python_bin, "-m", "pip", "install", "-U", "pip" })
      run_command_or_error({ python_bin, "-m", "pip", "install", "-r", requirements })
      run_command_or_error({ python_bin, "-c", IMPORT_PROBE })
    end
  end)

  if not ok then
    return nil, table.concat({
      "Ollama Copilot: failed to prepare managed Python environment.",
      ("venv: %s"):format(venv_dir),
      tostring(err),
    }, "\n")
  end

  return python_bin, nil
end

---@param user_config table|nil
---@return table
local function merged_config(user_config)
  return vim.tbl_deep_extend("force", vim.deepcopy(default_config), user_config or {})
end

local function disable_plugin()
  if not enabled then
    return
  end

  for _, client in ipairs(vim.lsp.get_clients({ name = "ollama_lsp" })) do
    client.stop()
  end

  enabled = false
end

---@param name string
---@param rhs function
---@param opts table
local function ensure_user_command(name, rhs, opts)
  if vim.fn.exists(":" .. name) == 2 then
    return
  end

  vim.api.nvim_create_user_command(name, rhs, opts)
end

---@param key string
---@return function
local function capture_insert_fallback(key)
  local keymaps = vim.api.nvim_get_keymap("i")
  for _, keymap in ipairs(keymaps) do
    if keymap.lhs == key and type(keymap.callback) == "function" then
      return keymap.callback
    end
  end

  return function()
    local termcoded = vim.api.nvim_replace_termcodes(key, true, false, true)
    vim.api.nvim_feedkeys(termcoded, "n", false)
  end
end

---@param provided table|nil
---@return table
local function resolve_capabilities(provided)
  if provided then
    return provided
  end

  local ok, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
  if ok and cmp_nvim_lsp and cmp_nvim_lsp.default_capabilities then
    return cmp_nvim_lsp.default_capabilities()
  end

  return vim.lsp.protocol.make_client_capabilities()
end

---@param config table
---@param root string
---@param python_bin string
local function configure_lsp(config, root, python_bin)
  local lsp_default = {
    cmd = { python_bin, root .. "python/ollama_lsp.py" },
    filetypes = config.filetypes,
    root_dir = function(fname)
      return lspconfig.util.find_git_ancestor(fname) or lspconfig.util.path.dirname(fname)
    end,
    settings = {},
    init_options = {
      model_name = config.model_name,
      ollama_url = config.ollama_url,
      stream_suggestion = config.stream_suggestion,
      ollama_model_opts = config.ollama_model_opts,
    },
  }

  if not configs.ollama_lsp then
    configs.ollama_lsp = {
      default_config = lsp_default,
    }
  else
    configs.ollama_lsp.default_config = vim.tbl_deep_extend("force", configs.ollama_lsp.default_config or {}, lsp_default)
  end

  local fallback_insert = capture_insert_fallback(config.keymaps.insert_accept)

  lspconfig.ollama_lsp.setup({
    capabilities = resolve_capabilities(config.capabilities),
    on_attach = function(_, bufnr)
      vim.keymap.set("i", config.keymaps.insert_accept, function()
        if ghost_text.is_visible() then
          ghost_text.accept_first_extmark_lines()
          return
        end

        fallback_insert()
      end, { buffer = bufnr, silent = true })
    end,
    handlers = {
      ["textDocument/completion"] = function() end,
      ["$/tokenStream"] = function(_, result)
        if not result or not result.completion or not result.completion.total then
          return
        end

        local opts = ghost_text.build_opts_from_text(result.completion.total)
        ghost_text.add_extmark(result.line, result.character, opts)
      end,
      ["$/clearSuggestion"] = function()
        ghost_text.delete_first_extmark()
      end,
    },
  })
end

---@param config table
local function configure_commands_and_autocmds(config)
  ensure_user_command("OllamaSuggestion", ollama_client.request_completions, { desc = "Get Ollama suggestion" })
  ensure_user_command("OllamaAccept", ghost_text.accept_first_extmark_lines, { desc = "Accept displayed Ollama suggestion" })
  ensure_user_command("OllamaReject", ghost_text.delete_first_extmark, { desc = "Reject displayed Ollama suggestion" })
  ensure_user_command("DisableOllamaCopilot", disable_plugin, { desc = "Disable Ollama Copilot" })

  local group = vim.api.nvim_create_augroup("OllamaCopilot", { clear = true })
  vim.api.nvim_create_autocmd({ "InsertLeave", "CursorMoved" }, {
    group = group,
    pattern = "*",
    callback = function()
      ghost_text.delete_first_extmark()
    end,
  })

  vim.keymap.set("n", config.keymaps.suggestion, "<Cmd>OllamaSuggestion<CR>", { silent = true })
  vim.keymap.set("n", config.keymaps.reject, "<Cmd>OllamaReject<CR>", { silent = true })
end

---Setup Ollama Copilot.
---@param user_config table|nil
function M.setup(user_config)
  local config = merged_config(user_config)
  local root = plugin_root()

  local python_bin, err = resolve_python_command(config, root)
  if not python_bin then
    notify_error(err)
    return
  end

  if (config.ollama_model_opts and config.ollama_model_opts.debug) or vim.env.OLLAMA_COPILOT_DEBUG == "1" then
    vim.schedule(function()
      vim.notify(("Ollama Copilot startup: python=%s root=%s"):format(python_bin, root), vim.log.levels.INFO)
    end)
  end

  configure_lsp(config, root, python_bin)
  configure_commands_and_autocmds(config)
end

return M
