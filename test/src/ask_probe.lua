-- A window that asks the compositor a question and keeps living.
--
-- Two modes, and the difference between them is the whole point of the check:
--   naive — wait for the answer by taking everything from the inbox (as before the fix);
--   ask   — wait for the answer on the topic's channel, without touching the inbox.
--
-- Reports what arrived AFTER the answer: a command the compositor sent while
-- the window was waiting must wait for the window's loop.
local process = require("process")
local channel = require("channel")
local time = require("time")
local desktop = require("desktop")

-- What else is in the inbox. The budget is short: everything that was due to
-- arrive has been sent by this moment.
local function drain(inbox, budget)
    local got = {}
    while true do
        local expiry = time.after(budget)
        local picked = channel.select({inbox:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then break end
        got[#got + 1] = picked.value:topic()
    end
    return table.concat(got, ",")
end

local function main(mode)
    local inbox = process.inbox()
    local answered, eaten = "no", {}

    if mode == "naive" then
        -- Exactly the loop being fixed here: someone else's message is read
        -- and thrown away, and there is nowhere to return it.
        local name = desktop.service()
        local pid = process.registry.lookup(name)
        process.send(pid, "desktop.list", {reply_to = tostring(process.pid())})

        local expiry = time.after("5s")
        while true do
            local picked = channel.select({inbox:case_receive(), expiry:case_receive()})
            if picked.channel == expiry or not picked.ok then break end
            local topic = picked.value:topic()
            if topic == desktop.REPLY_TOPIC then answered = "yes" break end
            eaten[#eaten + 1] = topic
        end
    else
        local answer, err = desktop.ask("desktop.list", {})
        answered = answer and tostring(answer.marker) or ("error: " .. tostring(err))
    end

    local sent, serr = process.send(tostring(desktop.service()), "probe.result", {
        answered = answered,
        eaten = table.concat(eaten, ","),
        handled = drain(inbox, "700ms"),
    })
    return sent, serr
end

return {main = main}
