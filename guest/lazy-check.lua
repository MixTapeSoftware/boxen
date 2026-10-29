-- Exits nvim with an error when any Lazy plugin is not installed, for
-- example because its host is missing from the kit's network allowlist.
local missing = {}
for _, plugin in ipairs(require('lazy').plugins()) do
  if not plugin.virtual and not plugin._.installed then
    table.insert(missing, plugin.name)
  end
end
if #missing > 0 then
  io.stderr:write('Lazy could not install: ' .. table.concat(missing, ', ') .. '\n')
  vim.cmd('cquit 1')
end
