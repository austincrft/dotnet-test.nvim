local M = {}

---@class BuildConfig : table
---@field args string[] Additional build args
---@field cmd_runner fun(cmd: string, callback?: fun())|nil A hook for customizing the build runner. AsyncRun is supported out of the box
---
---@class TestConfig : table
---@field args string[] Additional test args
---
---@class DapConfig : table
---@field type string The DAP type to use when debugging
---
---@class Config : table
---@field log_level vim.log.levels Log level
---@field find_target_max_iter number Max number of iterations up the filesystem to find a csproj or sln, starting from the test file
---@field build BuildConfig Build configuration
---@field test TestConfig Build configuration
local config = {
  log_level = vim.log.levels.WARN,
  find_target_max_iter = 10,
  build = {
    args = {},
    cmd_runner = nil,
  },
  test = {
    args = {},
  },
  dap = {
    type = 'coreclr'
  }
}

---@class PartialConfig
---@field log_level vim.log.levels|nil
---@field find_target_max_iter number|nil
---@field build BuildConfig|nil
---@field test TestConfig|nil
---Setup for plugin, optional if using defaults
---@param opts table
function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
end

local function notify(msg, level)
  if level >= config.log_level then
    vim.schedule(function()
      vim.notify("[dotnet-test] " .. msg, level)
    end)
  end
end

local function get_curr_csharp_method()
  local ts = vim.treesitter
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = ts.get_parser(bufnr, "c_sharp")
  if not parser then
    notify("No treesitter parser for C# installed", vim.log.levels.ERROR)
    return
  end

  local tree = parser:parse()[1]
  local root = tree:root()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]

  local found = nil
  local function node_contains_cursor(node)
    local start_row, start_col, end_row, end_col = node:range()
    if row < start_row or row > end_row then return false end
    if row == start_row and col < start_col then return false end
    if row == end_row and col > end_col then return false end
    return true
  end

  -- Find the innermost method_declaration node containing the cursor
  local function find_method(node)
    if node:type() == "method_declaration" and node_contains_cursor(node) then
      found = node
      for child in node:iter_children() do
        find_method(child)
      end
    else
      for child in node:iter_children() do
        find_method(child)
      end
    end
  end

  find_method(root)

  if not found then
    notify("Cursor is not inside a method.", vim.log.levels.WARN)
    return
  end

  -- Get method name
  local query = ts.query.parse("c_sharp", [[
    (method_declaration
      name: (identifier) @method_name)
  ]])
  local method_name = nil
  for id, node in query:iter_captures(found, bufnr, 0, -1) do
    if query.captures[id] == "method_name" then
      method_name = ts.get_node_text(node, bufnr)
      break
    end
  end
  if not method_name then
    notify("Method found, but could not get name.", vim.log.levels.ERROR)
    return
  end

  -- Walk up to collect class/struct/record and namespace names
  local names = { method_name }
  local parent = found:parent()
  local namespace_found = false
  while parent do
    local t = parent:type()
    if t == "class_declaration" or t == "struct_declaration" or t == "record_declaration" then
      -- Get class/struct/record name
      for child in parent:iter_children() do
        if child:type() == "identifier" then
          table.insert(names, 1, ts.get_node_text(child, bufnr))
          break
        end
      end
    elseif t == "namespace_declaration" then
      -- Get namespace name (could be a qualified_name or identifier)
      for child in parent:iter_children() do
        if child:type() == "qualified_name" or child:type() == "identifier" then
          table.insert(names, 1, ts.get_node_text(child, bufnr))
          namespace_found = true
          break
        end
      end
    end
    parent = parent:parent()
  end

  if not namespace_found then
    local file_scoped_ns = nil
    for child in root:iter_children() do
      if child:type() == "file_scoped_namespace_declaration" then
        for ns_child in child:iter_children() do
          if ns_child:type() == "qualified_name" or ns_child:type() == "identifier" then
            file_scoped_ns = ts.get_node_text(ns_child, bufnr)
            break
          end
        end
        break
      end
    end

    if file_scoped_ns then
      table.insert(names, 1, file_scoped_ns)
    end
  end

  return table.concat(names, ".")
end

local function glob_any(dir, patterns)
  for _, pat in ipairs(patterns) do
    local files = vim.fn.globpath(dir, pat, false, true)
    if #files > 0 then return files end
  end
  return {}
end

local function find_dotnet_target()
  local patterns = { "*.sln", "*.csproj" }
  local buf_dir = vim.fn.expand('%:p:h')

  -- Walk up from buf_dir
  local iter = 1
  local dir = buf_dir
  local cwd = vim.fn.getcwd()

  while iter ~= config.find_target_max_iter + 1 and dir and dir ~= "" and dir ~= "/" and dir ~= cwd do
    notify("Iter " .. tostring(iter) .. ": " .. dir, vim.log.levels.DEBUG)
    local targets = glob_any(dir, patterns)
    if not targets or #targets == 0 then
      notify("No targets found" .. dir, vim.log.levels.DEBUG)
    else
      if #targets == 1 then
        local target = targets[1]
        notify("target: " .. target, vim.log.levels.DEBUG)
        return target
      else
        -- TODO: Show picker
        local msg = "Multiple targets found at " .. dir .. ": " .. table.concat(targets, ", ")
        notify(msg, vim.log.levels.DEBUG)
        return
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if not parent or parent == dir then break end
    dir = parent
    iter = iter + 1
  end

  return nil
end

local function run_build_cmd(cmd, callback)
  if config.build and config.build.cmd_runner then
    config.build.cmd_runner(cmd, callback)
    return
  end

  vim.cmd("AsyncRun " .. cmd)
  vim.cmd("botright copen")

  if callback then
    vim.api.nvim_create_autocmd("User", {
      pattern = "AsyncRunStop",
      once = true,
      callback = function()
        if vim.g.asyncrun_status ~= "success" then
          notify("Build failed, not running test.", vim.log.levels.ERROR)
        else
          -- Close quickfix
          vim.cmd("cclose")

          callback()
        end
      end,
    })
  end
end

---@class CliOpts
---@field filter string|nil An optional filter for `dotnet test`
---@field target string|nil An optional target for `dotnet test`. If nil, a filesystem traversal will be done to find the nearest target
---@field debug boolean If true, `dotnet test` will run with a DAP debug session attached
--Run the `dotnet test` CLI
---@param opts CliOpts
function M.run_dotnet_test_cli(opts)
  opts = opts or { filter = nil, target = nil, debug = false }
  local target = opts.target or find_dotnet_target()
  if not target then
    notify("No .sln or .csproj provided or found.", vim.log.levels.ERROR)
    return
  end

  local build_cmd = "dotnet build \"" .. target .. "\" " .. table.concat(config.build.args, " ")

  if opts.debug then
    local function build_finished_callback()
      local dap = require('dap')
      local handle
      local stdout = vim.uv.new_pipe(false)

      notify("Starting dotnet test", vim.log.levels.DEBUG)

      local args = { "test", target, "--no-build" }

      if opts.filter and opts.filter ~= "" then
        table.insert(args, "--filter")
        table.insert(args, '"' .. opts.filter .. '"')
      end

      ---@diagnostic disable-next-line: missing-fields
      handle = vim.uv.spawn("dotnet", {
        args = args,
        env = { "VSTEST_HOST_DEBUG=1" },
        stdio = { nil, stdout, nil },
      }, function(code, signal)
        notify("Closing stdout and handle", vim.log.levels.DEBUG)
        if stdout then
          stdout:close()
        end
        handle:close()
      end)

      if not stdout then
        return
      end

      local dap_type = config.dap and config.dap.type or 'coreclr'

      stdout:read_start(function(err, data)
        notify("Starting read. Error=" .. vim.inspect(err) .. ";Data=" .. vim.inspect(data), vim.log.levels.DEBUG)
        if data then
          local test_pid = data:match('Process Id: (%d+)')
          if test_pid then
            notify("Attaching to test host: " .. test_pid, vim.log.levels.DEBUG)
            vim.schedule(function()
              dap.run({
                type = dap_type,
                name = 'Attach to Test Host',
                request = 'attach',
                processId = tonumber(test_pid)
              })
            end)
          end
        end
      end)
    end

    run_build_cmd(build_cmd, build_finished_callback)

    return
  end

  local test_cmd = 'dotnet test "' .. target .. '" --no-build ' ..  table.concat(config.test.args, " ")
  if opts.filter and opts.filter ~= "" then
   test_cmd = test_cmd .. ' --filter "' .. opts.filter .. '"'
  end
  run_build_cmd(table.concat({ build_cmd, test_cmd }, " && "))
end

---@class RunTestOpts
---@field test_name string|nil An optional filter for `dotnet test`
---@field debug boolean If true, `dotnet test` will run with a DAP debug session attached
---Run a single .NET test. The current test will be determined via treesitter or you can provide a test name directly
---@param opts RunTestOpts
function M.run_test(opts)
  opts = opts or { test_name = nil, debug = false }
  local test = opts.test_name and opts.test_name ~= "" or get_curr_csharp_method()
  if not test or test == "" then
    return
  end

  local filter = "FullyQualifiedName~" .. test
  M.run_dotnet_test_cli({ filter = filter, debug = opts.debug })
end

local function get_curr_file_toplevel_types()
  local ts = vim.treesitter
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = ts.get_parser(bufnr, "c_sharp")
  if not parser then
    notify("No treesitter parser for C# installed", vim.log.levels.ERROR)
    return {}
  end

  local function get_namespace(node)
    local type = node:type()
    local is_file_scoped
    if type == "file_scoped_namespace_declaration" then
      is_file_scoped = true
    elseif type == "namespace_declaration" then
      is_file_scoped = false
    else
      return nil
    end

    for ns_child in node:iter_children() do
      if ns_child:type() == "identifier" then
        return { is_file_scoped = is_file_scoped, name = ts.get_node_text(ns_child, bufnr) }
      end
    end
    return nil
  end

  local function get_child_types(namespace, node)
    local type = node:type()

    if type == "class_declaration" or type == "struct_declaration" or type == "record_declaration" then
      local type_name = nil
      for type_child in node:iter_children() do
        if type_child:type() == "identifier" then
          type_name = ts.get_node_text(type_child, bufnr)
          break
        end
      end

      if type_name then
        if namespace then
          return namespace .. "." .. type_name
        else
          return type_name
        end
      end
    end
  end


  local file_scoped_namespace
  local types = {}
  local tree = parser:parse()[1]
  local root = tree:root()

  -- Iterate syntax tree for top-level types
  for child in root:iter_children() do
    local namespace = file_scoped_namespace and nil or get_namespace(child)
    if namespace then
      -- For file-scoped namespace, store name and continue iteration at this level
      if namespace.is_file_scoped then
        file_scoped_namespace = namespace.name
        notify("file-scoped namespace: " .. file_scoped_namespace, vim.log.levels.DEBUG)
        goto continue
      end

      -- For block-scoped namespace, iterate children
      notify("block-scoped namespace: " .. namespace.name, vim.log.levels.DEBUG)
      for ns_child in child:iter_children() do
        local ns_child_type = ns_child:type()
        if ns_child_type == "declaration_list" then
          for declaration_child in ns_child:iter_children() do
            local type_name = get_child_types(namespace.name, declaration_child)
            table.insert(types, type_name)
          end
        end
      end
    else
      local type_name = get_child_types(file_scoped_namespace or nil, child)
      table.insert(types, type_name)
    end

    ::continue::
  end

  return types
end

---@class RunFileOpts
---@field target string|nil An optional target for `dotnet test`. If nil, a filesystem traversal will be done to find the nearest target
---@field debug boolean If true, `dotnet test` will run with a DAP debug session attached
---Run all .NET tests in the current file
---@param opts RunFileOpts
function M.run_current_file(opts)
  opts = opts or { target = nil, debug = false }
  local type_names = get_curr_file_toplevel_types()
  if not type_names or #type_names == 0 then
    notify("No top-level types found in the current file", vim.log.levels.ERROR)
    return
  end

  notify("top-level types: " .. table.concat(type_names, ", "), vim.log.levels.DEBUG)

  local filters = {}
  for i, v in ipairs(type_names) do
    filters[i] = "FullyQualifiedName~" .. v
  end

  local filter = table.concat(filters, " | ")
  notify("filter: " .. filter, vim.log.levels.DEBUG)

  M.run_dotnet_test_cli({ target = opts.target, filter = filter, debug = opts.debug })
end

---@class RunTargetOpts
---@field target string|nil An optional target for `dotnet test`. If nil, a filesystem traversal will be done to find the nearest target
---@field debug boolean If true, `dotnet test` will run with a DAP debug session attached
---Run all .NET tests for a target. The selected roslyn sln will be used or a target can be provided directly
---@param opts RunTargetOpts
function M.run_target(opts)
  opts = opts or { target = nil, debug = false }
  local target = opts.target or vim.g.roslyn_nvim_selected_solution
  if not target or target == "" then
    notify("No target provided or selected in roslyn", vim.log.levels.ERROR)
  end

  M.run_dotnet_test_cli({ target = target, debug = opts.debug } )
end

return M
