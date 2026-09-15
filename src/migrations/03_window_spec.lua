-- Описание окна из мастерской сверх кода: импорты библиотек, значок, тип
-- окна, пиксельный вид.
--
-- До этой колонки окно из мастерской умело только рисовать себя само на tty:
-- импорт у него был один, фиксированный. Окно на SDK оболочки — дерево
-- компонентов, общий отрисовщик, пиксельный вид — объявляет импорт `app` и
-- `pixel_render`, и объявить их было негде. Одна колонка JSON, а не колонка
-- на поле: поля эти — форма записи реестра, и расти они будут вместе с ней.
--
-- '{}' — «ничего не объявлено»: окно собирается как раньше.

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
