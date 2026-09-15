-- Папка меню у окна, собранного в рантайме.
--
-- У записи из файла папку называет `meta.group`; у окна из мастерской
-- объявить её негде — код приезжает по HTTP, и всё, что о нём известно,
-- лежит в этой таблице. Без колонки каждое такое окно ложилось туда, куда
-- оболочка кладёт безымянных, и меню росло с каждым собранным окном.
--
-- Пустая строка — «папка не названа»: загрузчик тогда `meta.group` не пишет
-- вовсе, и оболочка решает сама. Так «не сказал» остаётся отличимым от
-- «сказал: корень», как и у записей из файлов.

return require("migration").define(function()
    migration("Add menu_group to windows_tui_desktop_windows", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    ALTER TABLE windows_tui_desktop_windows
                        ADD COLUMN menu_group TEXT NOT NULL DEFAULT ''
                ]])
                if err then error("Failed to add menu_group: " .. err) end
            end)
            down(function(db) db:execute("ALTER TABLE windows_tui_desktop_windows DROP COLUMN menu_group") end)
        end)
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    ALTER TABLE windows_tui_desktop_windows
                        ADD COLUMN menu_group TEXT NOT NULL DEFAULT ''
                ]])
                if err then error("Failed to add menu_group: " .. err) end
            end)
            down(function(db) db:execute("ALTER TABLE windows_tui_desktop_windows DROP COLUMN menu_group") end)
        end)
    end)
end)
