-- Окно с настоящей программой.
--
-- Процесс получает обычный tty-порт — на деле viewport композитора — и
-- отдаёт его программе под PTY. Он не знает ни своего положения на экране,
-- ни того, что поверх него лежат другие окна; в этом весь смысл границы.
--
-- Своей поверхности здесь нет и быть не может: attach_terminal() забирает
-- аренду порта себе, а аренда одна на порт.

local channel = require("channel")
local exec = require("exec")
local tty = require("tty")

local EXECUTOR = "windows.tui_desktop:exec"
-- Interactive Bash reads ~/.bashrc; the host config supplies HOME and PATH
-- on the dedicated PTY executor (exec.native does not inherit OS variables).
local DEFAULT_COMMAND = "/bin/bash -i"

local function main(command)
    -- Подписка до старта: start() эмитит первое событие, и подписчик должен
    -- уже существовать.
    local events = assert(tty.events())
    assert(tty.start())

    local executor = assert(exec.get(EXECUTOR))

    -- Размер PTY не задаём: attach_terminal читает screen_size() порта, то
    -- есть внутренний размер окна. Дальше его двигают события resize,
    -- которые композитор шлёт при перетаскивании края.
    local proc, perr = executor:exec(
        type(command) == "string" and command ~= "" and command or DEFAULT_COMMAND,
        {pty = {term = "xterm-256color"}})
    if not proc then
        executor:release()
        error("the window could not start the program: " .. tostring(perr))
    end

    -- attach_terminal ПОГЛОЩАЕТ proc: дальше владелец жизненного цикла —
    -- сессия, а исходной ручкой пользоваться нельзя.
    local session, serr = proc:attach_terminal()
    if not session then
        executor:release()
        error("the window could not take the terminal: " .. tostring(serr))
    end

    local done = session:done()

    while true do
        local selected = channel.select({
            events:case_receive(),
            done:case_receive(),
        })
        if not selected.ok or selected.channel == done then break end

        local event = selected.value
        -- `close` присылает композитор; настоящий терминал такого не эмитит.
        if event.type == "close" then break end

        -- Голым `return session:send(event)` этот вызов писать нельзя:
        -- хвостовой вызов yield-функции в go-lua v1.5.18 не выполняется.
        assert(session:send(event))
    end

    assert(session:close())
    assert(executor:release())
    assert(tty.stop())
end

return {main = main}
