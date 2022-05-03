local M = {}




local state = require("crates.state")
local toml = require("crates.toml")
local types = require("crates.types")
local CrateInfo = types.CrateInfo
local Diagnostic = types.Diagnostic
local Version = types.Version

local CUSTOM_NS = vim.api.nvim_create_namespace("crates.nvim")
local DIAGNOSTIC_NS = vim.api.nvim_create_namespace("crates.nvim.diagnostic")

M.custom_diagnostics = {}
M.diagnostics = {}

local function to_vim_diagnostic(d)
   local diag = {
      lnum = d.lnum,
      end_lnum = d.end_lnum,
      col = d.col,
      end_col = d.end_col,
      severity = d.severity,
      message = d.message,
      source = "crates",
   }
   return diag
end

function M.display_diagnostics(buf, diagnostics)
   if not state.visible then return end

   M.diagnostics[buf] = M.diagnostics[buf] or {}
   local vim_diagnostics = vim.tbl_map(to_vim_diagnostic, diagnostics)
   vim.list_extend(M.diagnostics[buf], vim_diagnostics)

   vim.diagnostic.set(DIAGNOSTIC_NS, buf, M.diagnostics[buf])
end

function M.display_crate_info(buf, info, diagnostics)
   if not state.visible then return end

   M.custom_diagnostics[buf] = M.custom_diagnostics[buf] or {}
   local vim_diagnostics = vim.tbl_map(to_vim_diagnostic, diagnostics)
   vim.list_extend(M.custom_diagnostics[buf], vim_diagnostics)

   local virt_text = {}
   if info.vers_match then
      local match = info.vers_match
      table.insert(virt_text, {
         string.format(state.cfg.text[info.match_kind], match.num),
         state.cfg.highlight[info.match_kind],
      })
   elseif info.match_kind == "nomatch" then
      table.insert(virt_text, {
         state.cfg.text.nomatch,
         state.cfg.highlight.nomatch,
      })
   end
   if info.vers_change then
      local new = info.vers_change
      if info.change_kind == "upgrade" then
         table.insert(virt_text, {
            string.format(state.cfg.text.upgrade, new.num),
            state.cfg.highlight.upgrade,
         })
      elseif info.change_kind == "downgrade" then
         table.insert(virt_text, {
            string.format(state.cfg.text.downgrade, new.num),
            state.cfg.highlight.downgrade,
         })
      end
   end
   if not (info.vers_match or info.vers_change) then
      table.insert(virt_text, {
         state.cfg.text.error,
         state.cfg.highlight.error,
      })
   end

   vim.diagnostic.set(CUSTOM_NS, buf, M.custom_diagnostics[buf], { virtual_text = false })
   vim.api.nvim_buf_clear_namespace(buf, CUSTOM_NS, info.lines.s, info.lines.e)
   vim.api.nvim_buf_set_extmark(buf, CUSTOM_NS, info.vers_line, -1, {
      virt_text = virt_text,
      virt_text_pos = "eol",
      hl_mode = "combine",
   })
end

function M.display_loading(buf, crate)
   if not state.visible then return end

   local virt_text = { { state.cfg.text.loading, state.cfg.highlight.loading } }
   vim.api.nvim_buf_clear_namespace(buf, CUSTOM_NS, crate.lines.s, crate.lines.e)
   local vers_line = crate.vers and crate.vers.line or crate.lines.s
   vim.api.nvim_buf_set_extmark(buf, CUSTOM_NS, vers_line, -1, {
      virt_text = virt_text,
      virt_text_pos = "eol",
      hl_mode = "combine",
   })
end

function M.clear(buf)
   M.custom_diagnostics[buf] = nil
   M.diagnostics[buf] = nil

   vim.api.nvim_buf_clear_namespace(buf, CUSTOM_NS, 0, -1)
   vim.diagnostic.reset(CUSTOM_NS, buf)
   vim.diagnostic.reset(DIAGNOSTIC_NS, buf)
end

return M
