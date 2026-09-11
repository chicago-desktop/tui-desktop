-- GET /tui-desktop/windows — что сейчас открыто на экране.
--
-- Аутентификацию обеспечивает роутер (token_auth + endpoint_firewall);
-- проверка актора держит честными прямые вызовы.
local http = require("http")
local security = require("security")
local control = require("control")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then return nil, "no http context" end
    res:set_content_type(http.CONTENT.JSON)

    if not security.actor() then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({success = false, error = "authentication required"})
        return
    end

    -- ?frame_samples=1 — сырые кадры кольца замера (до двухсот строк): нужны
    -- замеру по фазам, в обычном статусе только лишний вес.
    local samples_wanted = req:query("frame_samples") == "1"
    local answer, err = control.call("desktop.list", {frame_samples = samples_wanted})
    if not answer then
        res:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        res:write_json({success = false, error = err})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        windows = answer.windows or {},
        focused = answer.focused,
        screen = answer.screen,
        -- Что стало с сохранёнными окнами на старте: молчание здесь читалось
        -- бы как «окон не было», а это другое утверждение.
        restore = answer.restore,
        -- Состояние стола целиком, а не только список окон. Каждое поле здесь
        -- различает два состояния, которые СНАРУЖИ выглядят одинаково: отказ,
        -- который видит только человек в строке состояния; открытое меню
        -- против недошедшего щелчка; раскрытая папка против нераскрытой;
        -- «раскрывать нечего» против «сломано»; выделенный значок против
        -- ненарисованного выделения; цена кадра, по которой видно неверно
        -- порезанный хром — он рисует правильный экран, просто медленный.
        --
        -- Композитор их уже отдаёт; не пробросить их здесь значило бы, что с
        -- живого стенда, где всё это и нужно, ими воспользоваться нельзя.
        notice = answer.notice,
        menu_open = answer.menu_open,
        menu_path = answer.menu_path,
        menu_choices = answer.menu_choices,
        menu_folders = answer.menu_folders,
        selected = answer.selected,
        pixels = answer.pixels,
        frame = answer.frame,
    })
end

return {handler = handler}
