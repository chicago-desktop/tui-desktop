-- Командный канал к композитору.
--
-- Композитор — обычный процесс, зарегистрированный под именем. HTTP-вызов
-- находит его по имени, шлёт сообщение и ждёт ответа на собственный inbox:
-- вызов способности сам исполняется процессом, что и делает ожидание
-- возможным.
--
-- Отсюда важное следствие для читателя ответа: «десктоп не отвечает» и
-- «десктоп не запущен» — разные вещи, и различать их обязан канал, иначе
-- незапущенный десктоп выглядит как сломанный.

local channel = require("channel")
local process = require("process")
local time = require("time")

-- Протокол «спросить композитор» один на всех, кто спрашивает: окно, ручка и
-- сам композитор. Топик ответа берётся оттуда, а не повторяется строкой.
local window_api = require("window_api")

local SERVICE_NAME = "windows.tui_desktop.desktop"
local REPLY_TOPIC = window_api.REPLY_TOPIC
local BUDGET = "5s"

local control = {}

-- Сообщение приезжает обёрнутым: payload — userdata, внутри бывает ещё и
-- массив из одного элемента. Поле, прочитанное напрямую, окажется nil без
-- всякой ошибки.
local function unwrap(value)
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        if ok and type(decoded) == "table" then return decoded end
        return {}
    end
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil and #value > 0 then return unwrap(value[1]) end
    return value
end

control.unwrap = unwrap

local function await(budget)
    local inbox = process.inbox()
    local expiry = time.after(budget)

    while true do
        local result = channel.select({inbox:case_receive(), expiry:case_receive()})
        if result.channel == expiry then
            return nil, "the desktop did not answer within " .. budget
        end
        if not result.ok then
            return nil, "the call's inbox closed while waiting for the desktop"
        end
        local message = result.value
        if message:topic() == REPLY_TOPIC then
            return unwrap(message:payload()), nil
        end
        -- Чужое сообщение не съедаем: оно адресовано не нам.
    end
end

-- call(topic, body) -> (ответ, nil) | (nil, причина)
--
-- Команды без ответа не бывает: молчание композитора невозможно отличить
-- от применённой команды, и вызывающий поверил бы в успех.
function control.call(topic, body)
    local pid, lerr = process.registry.lookup(SERVICE_NAME)
    if not pid then
        return nil, "the desktop is not running (" .. tostring(lerr)
            .. "): start it with `wippy run --host windows.tui_desktop:terminal desktop`"
    end

    body = type(body) == "table" and body or {}
    body.reply_to = process.pid()

    local sent, serr = process.send(pid, topic, body)
    if not sent then
        return nil, "could not pass the command to the desktop: " .. tostring(serr)
    end

    local answer, aerr = await(BUDGET)
    if not answer then return nil, aerr end
    if answer.ok == false then
        return nil, tostring(answer.error or "the desktop refused without a reason")
    end
    return answer, nil
end

return control
