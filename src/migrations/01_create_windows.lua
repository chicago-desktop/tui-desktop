-- Хранилище окон, собранных в работающем рантайме.
--
-- Реестр собирается из файлов при старте, поэтому применённая версия его не
-- переживает. Эта таблица — то, из чего окна поднимаются обратно: загрузчик
-- читает её на старте и применяет записи в реестр.
--
-- Одна строка на окно: имя и есть ключ. Повторная сборка перезаписывает —
-- истории правок здесь нет намеренно, иначе понадобились бы ручки списка
-- версий и отката, а откат к неработавшему коду ценности не имеет.

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
