-- Оболочка по умолчанию: композитор со штатной темой.
--
-- Вся механика — в `library`; здесь только выбор вида и имени, под которым
-- десктоп виден процессам. Вторая оболочка (другой модуль) зовёт ту же
-- библиотеку со своей темой и своим именем, не копируя ни хостинг окон, ни
-- PTY, ни командный канал.

local library = require("library")
local chrome = require("chrome")

local function main()
    -- Голым `return library.run(...)` это писать нельзя: в go-lua v1.5.18
    -- хвостовой вызов yield-функции из базового фрейма корутины не
    -- выполняется вовсе — молча, за 0 мс.
    local ok, err = library.run({
        chrome = chrome,
        service_name = "butschster.tui_desktop.desktop",
        hint = "alt+n — bash window · alt+o — applications · ctrl+q — quit",
    })
    return ok, err
end

return {main = main}
