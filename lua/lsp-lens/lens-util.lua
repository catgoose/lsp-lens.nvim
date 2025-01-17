local lsplens = {}
local config = require('lsp-lens.config')
local utils = require('lsp-lens.utils')

local lsp = vim.lsp

local methods = {
  'textDocument/definition',
  'textDocument/implementation',
  'textDocument/references',
}

local function result_count(results)
  local ret = 0
  for _, res in pairs(results or {}) do
    for _, _ in pairs(res.result or {}) do
      ret = ret + 1
    end
  end
  return ret
end

local function requests_done(finished)
  for _, p in pairs(finished) do
    if not (p[1] == true and p[2] == true and p[3] == true) then
      return false
    end
  end
  return true
end

local function get_functions(result)
  local ret = {}
  for _, v in pairs(result or {}) do
    if v.kind == 12 or v.kind == 6 then
      table.insert(ret, { name = v.name, rangeStart = v.range.start, selectionRangeStart = v.selectionRange.start })
    elseif v.kind == 23 or v.kind == 5 then
      ret = utils:merge_table(ret, get_functions(v.children))
    end
  end
  return ret
end

local function get_cur_document_functions(results)
  local ret = {}
  for _, res in pairs(results or {}) do
    ret = utils:merge_table(ret, get_functions(res.result))
  end
  return ret
end

local function lsp_support_method(buf, method)
  for _, client in pairs(lsp.get_active_clients({ bufnr = buf })) do
    if client.supports_method(method) then
      return true
    end
  end
  return false
end

local function create_string(counting)
  local text = ""
  if counting.definition and counting.definition > 0 then
    text = text .. "Definition:" .. counting.definition .. " | "
  end
  if counting.implementation and counting.implementation > 0 then
    text = text .. "Implementation:" .. counting.implementation .. " | "
  end
  if counting.references and counting.references > 0 then
    text = text .. "References:" .. counting.references
  end
  if text:sub(-3) == ' | ' then
    text = text:sub(1, -4)
  end
  return text
end

local function generate_function_id(function_info)
  return function_info.name ..
    "uri=" .. function_info.query_params.textDocument.uri ..
    "character=" .. function_info.selectionRangeStart.character ..
    "line=" .. function_info.selectionRangeStart.line
end

local function delete_existing_lines(bufnr, ns_id)
  local existing_marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  for _, v in pairs(existing_marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns_id, v[1])
  end
end

local function display_lines(bufnr, query_results)
  local ns_id = vim.api.nvim_create_namespace('lsp-lens')
  delete_existing_lines(bufnr, ns_id)
  for _, query in pairs(query_results or {}) do
    local virt_lines = {}
    local vline = { {string.rep(" ", query.rangeStart.character) .. create_string(query.counting), "LspLens"} }
    table.insert(virt_lines, vline)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, query.rangeStart.line - 1, 0, {virt_lines = virt_lines})
  end
end

local function do_request(symbols)
  local functions = symbols.document_functions_with_params
  local finished = {}

  for idx, function_info in pairs(functions or {}) do
    table.insert(finished, { false, false, false })

    local params = function_info.query_params
    local counting = {}

    if lsp_support_method(vim.api.nvim_get_current_buf(), methods[2]) then
      lsp.buf_request_all(symbols.bufnr, methods[2], params, function(implements)
        counting["implementation"] = result_count(implements)
        finished[idx][1] = true
      end)
    else
      finished[idx][1] = true
    end

    lsp.buf_request_all(symbols.bufnr, methods[1], params, function(definition)
      counting["definition"] = result_count(definition)
      finished[idx][2] = true
    end)

    params.context = { includeDeclaration = config.config.include_declaration }
    lsp.buf_request_all(symbols.bufnr, methods[3], params, function(references)
      counting["references"] = result_count(references)
      finished[idx][3] = true
    end)

    function_info["counting"] = counting
  end

  local timer = vim.loop.new_timer()
  timer:start(0, 100, vim.schedule_wrap(function()
    if requests_done(finished) then
      timer:stop()
      timer:close()
      display_lines(symbols.bufnr, functions)
    end
  end))
end

local function make_params(results)
  for _, query in pairs(results or {}) do
    local params = {
      position = {
        character = query.selectionRangeStart.character,
        line = query.selectionRangeStart.line
      },
      textDocument = lsp.util.make_text_document_params()
    }
    query.query_params = params
  end
  return results
end

function lsplens:lsp_lens_on()
  config.config.enable = true
  lsplens:procedure()
end

function lsplens:lsp_lens_off()
  config.config.enable = false
  delete_existing_lines(0, vim.api.nvim_create_namespace('lsp-lens'))
end

function lsplens:lsp_lens_toggle()
  if config.config.enable then
    lsplens:lsp_lens_off()
  else
    lsplens:lsp_lens_on()
  end
end


function lsplens:procedure()
  if config.config.enable == false then
    lsplens:lsp_lens_off()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local method = 'textDocument/documentSymbol'
  if lsp_support_method(bufnr, method) then
    local params = { textDocument = lsp.util.make_text_document_params() }
    lsp.buf_request_all(bufnr, method, params, function(document_symbols)
      local symbols = {}
      symbols["bufnr"] = bufnr
      symbols["document_symbols"] = document_symbols
      symbols["document_functions"] = get_cur_document_functions(symbols.document_symbols)
      symbols["document_functions_with_params"] = make_params(symbols.document_functions)
      do_request(symbols)
    end)
  end
end

return lsplens
