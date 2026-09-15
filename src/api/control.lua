-- The command channel to the compositor.
--
-- The compositor is an ordinary process registered under a name. An HTTP call
-- finds it by name, sends a message and waits for the reply in its own inbox:
-- the capability call is itself executed by a process, which is what makes
-- the wait possible.
--
-- Hence an important consequence for whoever reads the reply: "the desktop
-- does not answer" and "the desktop is not running" are different things, and
-- the channel must tell them apart, otherwise a desktop that is not running
-- looks broken.

local channel = require("channel")
local process = require("process")
local time = require("time")

-- The "ask the compositor" protocol is one for everyone who asks: a window, an
-- endpoint and the compositor itself. The reply topic is taken from there, not
-- repeated as a string.
local window_api = require("window_api")

local SERVICE_NAME = "chicago.tui_desktop.desktop"
local REPLY_TOPIC = window_api.REPLY_TOPIC
local BUDGET = "5s"

local control = {}

-- A message arrives wrapped: the payload is userdata, and inside there is
-- sometimes also a one-element array. A field read directly comes out nil
-- without any error.
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
        -- A foreign message is not eaten: it is not addressed to us.
    end
end

-- call(topic, body) -> (reply, nil) | (nil, reason)
--
-- There is no command without a reply: the compositor's silence cannot be told
-- apart from an applied command, and the caller would believe in success.
function control.call(topic, body)
    local pid, lerr = process.registry.lookup(SERVICE_NAME)
    if not pid then
        return nil, "the desktop is not running (" .. tostring(lerr)
            .. "): start it with `wippy run --host chicago.tui_desktop:terminal desktop`"
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
