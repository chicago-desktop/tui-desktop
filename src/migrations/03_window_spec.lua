-- The workshop window's description beyond the code: library imports, icon,
-- window type, pixel view.
--
-- Before this column a workshop window could only draw itself on tty: it had
-- one import, a fixed one. A window on the shell's SDK — a component tree, a
-- shared renderer, a pixel view — declares the `app` import and
-- `pixel_render`, and there was nowhere to declare them. One JSON column, not
-- a column per field: these fields are the shape of a registry entry, and
-- they will grow along with it.
--
-- '{}' — "nothing declared": the window is built as before.

return require("migration").define(function()
    migration("Add spec to windows_tui_desktop_windows", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    ALTER TABLE windows_tui_desktop_windows
                        ADD COLUMN spec TEXT NOT NULL DEFAULT '{}'
                ]])
                if err then error("Failed to add spec: " .. err) end
            end)
            down(function(db) db:execute("ALTER TABLE windows_tui_desktop_windows DROP COLUMN spec") end)
        end)
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    ALTER TABLE windows_tui_desktop_windows
                        ADD COLUMN spec TEXT NOT NULL DEFAULT '{}'
                ]])
                if err then error("Failed to add spec: " .. err) end
            end)
            down(function(db) db:execute("ALTER TABLE windows_tui_desktop_windows DROP COLUMN spec") end)
        end)
    end)
end)
