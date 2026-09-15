-- Storage of windows built in the running runtime.
--
-- The registry is assembled from files at start, so an applied version does
-- not survive the start. This table is what windows are brought back from:
-- the loader reads it at start and applies the entries to the registry.
--
-- One row per window: the name is the key. A repeated build overwrites — there
-- is no edit history here on purpose, otherwise endpoints for listing versions
-- and rolling back would be needed, and a rollback to code that did not work
-- has no value.

return require("migration").define(function()
    migration("Create windows_tui_desktop_windows table", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE windows_tui_desktop_windows (
                        name TEXT PRIMARY KEY,
                        title TEXT NOT NULL,
                        width INTEGER NOT NULL,
                        height INTEGER NOT NULL,
                        source TEXT NOT NULL,
                        modules TEXT NOT NULL DEFAULT '[]',
                        created_at TEXT NOT NULL DEFAULT (to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
                        updated_at TEXT NOT NULL DEFAULT (to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                    );
                ]])
                if err then error("Failed to create windows_tui_desktop_windows: " .. err) end
            end)
            down(function(db) db:execute("DROP TABLE windows_tui_desktop_windows") end)
        end)
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE windows_tui_desktop_windows (
                        name TEXT PRIMARY KEY,
                        title TEXT NOT NULL,
                        width INTEGER NOT NULL,
                        height INTEGER NOT NULL,
                        source TEXT NOT NULL,
                        modules TEXT NOT NULL DEFAULT '[]',
                        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                    )
                ]])
                if err then error("Failed to create windows_tui_desktop_windows: " .. err) end
            end)
            down(function(db) db:execute("DROP TABLE windows_tui_desktop_windows") end)
        end)
    end)
end)
