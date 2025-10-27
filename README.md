# dotnet-test.nvim

A simple plugin for running .NET tests from Neovim.

## Usage

This plugin exposes a few methods for running tests

```lua
local dotnet_test = require("dotnet-test")

-- Will run the current test
dotnet_test.run_test()

-- Will run the current test with a DAP debug session attached
-- All funcs here accept a debug option like this
dotnet_test.run_test({ debug = true })

-- Will run all tests in the current file
dotnet_test.run_current_file()

-- Will run all tests in the current sln
dotnet_test.run_target()

-- Lower-level wrapper for invoking the `dotnet test` CLI
-- Used by the funcs above
dotnet_test.run_dotnet_test_cli()
```

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  "austincrft/dotnet-test.nvim",
  dependencies = {
     -- Used as the default build runner. Optional if you implement your own via build.cmd_runner
    "skywind3000/asyncrun.vim",
    -- Used to run all tests in the current sln. Optional if you don't use this feature or provide an explicit target
    "seblyng/roslyn.nvim"
  },
  config = function()
    local dotnet_test = require("dotnet-test")

    -- This plugin does not require calling setup if you're using defaults.
    -- I find the `dotnet build` cmd verbose so I set it to quiet
    dotnet_test.setup({
      build = {
        args = { "--verbosity", "quiet" },
      },
    })

    -- Creates buffer-scoped mappings for tests
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "cs",
      callback = function()
        vim.keymap.set("n", "<Leader>tt", function()
          dotnet_test.run_test()
        end, {
          noremap = true,
          silent = true,
          buffer = true,
          desc = "Run .NET test"
        })

        vim.keymap.set("n", "<Leader>td", function()
          dotnet_test.run_test({ debug = true })
        end, {
          noremap = true,
          silent = true,
          buffer = true,
          desc = "Debug .NET test"
        })

        vim.keymap.set("n", "<Leader>tf", function()
          dotnet_test.run_current_file()
        end, {
          noremap = true,
          silent = true,
          buffer = true,
          desc = "Debug .NET tests in file"
        })

        vim.keymap.set("n", "<Leader>ts", function()
          dotnet_test.run_target()
        end, {
          noremap = true,
          silent = true,
          buffer = true,
          desc = "Run .NET tests in sln or proj"
        })
      end,
    })
  end,
},
```

