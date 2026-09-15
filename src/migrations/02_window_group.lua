-- The menu folder of a window built in the runtime.
--
-- For an entry from a file the folder is named by `meta.group`; a window from
-- the workshop has nowhere to declare it — the code arrives over HTTP, and all
-- that is known about it lies in this table. Without the column every such
-- window landed where the shell puts unnamed ones, and the menu grew with each
-- built window.
--
-- An empty string is "the folder is not named": the loader then does not write
-- `meta.group` at all, and the shell decides itself. That way "did not say"
-- stays distinguishable from "said: root", as with entries from files.

return require("migration").define(function()
    migration("Add menu_group to chicago_tui_desktop_windows", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    ALTER TABLE chicago_tui_desktop_windows
                        ADD COLUMN menu_group TEXT NOT NULL DEFAULT ''
                ]])
                if err then error("Failed to add menu_group: " .. err) end
            end)
            down(function(db) db:execute("ALTER TABLE chicago_tui_desktop_windows DROP COLUMN menu_group") end)
        end)
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    ALTER TABLE chicago_tui_desktop_windows
                        ADD COLUMN menu_group TEXT NOT NULL DEFAULT ''
                ]])
                if err then error("Failed to add menu_group: " .. err) end
            end)
            down(function(db) db:execute("ALTER TABLE chicago_tui_desktop_windows DROP COLUMN menu_group") end)
        end)
    end)
end)
