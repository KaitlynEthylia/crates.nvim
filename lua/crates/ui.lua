local M = {}






local core = require("crates.core")
local diagnostic = require("crates.diagnostic")
local CrateInfo = diagnostic.CrateInfo
local toml = require("crates.toml")
local Crate = toml.Crate

M.custom_ns = vim.api.nvim_create_namespace("crates.nvim")
M.custom_diagnostics = {}
M.diagnostic_ns = vim.api.nvim_create_namespace("crates.nvim.diagnostic")
M.diagnostics = {}

function M.display_diagnostics(buf, diagnostics)
   if not core.visible then return end

   M.diagnostics[buf] = M.diagnostics[buf] or {}
   vim.list_extend(M.diagnostics[buf], diagnostics)

   vim.diagnostic.set(M.diagnostic_ns, buf, M.diagnostics[buf])
end

function M.display_crate_info(buf, info)
   if not core.visible then return end

   M.custom_diagnostics[buf] = M.custom_diagnostics[buf] or {}
   vim.list_extend(M.custom_diagnostics[buf], info.diagnostics)

   vim.diagnostic.set(M.custom_ns, buf, M.custom_diagnostics[buf], { virtual_text = false })
   vim.api.nvim_buf_clear_namespace(buf, M.custom_ns, info.lines.s, info.lines.e)
   vim.api.nvim_buf_set_extmark(buf, M.custom_ns, info.vers_line, -1, {
      virt_text = info.virt_text,
      virt_text_pos = "eol",
      hl_mode = "combine",
   })
end

function M.display_loading(buf, crate)
   if not core.visible then return end

   local virt_text = { { core.cfg.text.loading, core.cfg.highlight.loading } }
   vim.api.nvim_buf_clear_namespace(buf, M.custom_ns, crate.lines.s, crate.lines.e)
   local vers_line = crate.vers and crate.vers.line or crate.lines.s
   vim.api.nvim_buf_set_extmark(buf, M.custom_ns, vers_line, -1, {
      virt_text = virt_text,
      virt_text_pos = "eol",
      hl_mode = "combine",
   })
end

function M.clear(buf)
   M.custom_diagnostics[buf] = nil
   M.diagnostics[buf] = nil

   vim.api.nvim_buf_clear_namespace(buf, M.custom_ns, 0, -1)
   vim.diagnostic.reset(M.custom_ns, buf)
   vim.diagnostic.reset(M.diagnostic_ns, buf)
end

return M
