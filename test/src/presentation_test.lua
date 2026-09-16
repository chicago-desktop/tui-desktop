-- A close is a request a window may refuse (Notepad's "save changes?").
--
-- The title bar's ×, ctrl+w and a plain `desktop.close` send `close` and wait:
-- a window that answers by closing goes; one that does not stays after the
-- grace (3 s), and the status line says "<title> did not close". Shutdown and
-- `desktop.close{force = true}` kill after the grace, as every close did
-- before; a PTY window is always closed that way.
--
-- A file of its own: it boots two compositors and waits out the grace twice,
-- and the harness gives each file thirty seconds.
local test = require("test")
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local function body_of(message: any): any
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function pause(duration: string)
    channel.select({time.after(duration):case_receive()})
end

local function boot(service: string, kind: string?): any
    local watcher = service .. ".watcher"
    process.registry.register(watcher)
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "the viewport was not created")
    local pid, err = process.with_options({terminal = view:grant()})
        :spawn_monitored("app:test_composer_pixels", "app:processes", service .. "|" .. watcher .. "|" .. (kind or "ok"))
    test.is_nil(err)
    test.not_nil(pid, "the compositor did not start")
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(service) then break end
        pause("100ms")
    end
    test.not_nil(process.registry.lookup(service), "the compositor did not register as " .. service)
    return {pid = pid, view = view, service = service, watcher = watcher}
end

-- A command with a reply, heard on the reply topic subscribed BEFORE sending.
local function ask(desk: any, topic: string, body: any): any
    local payload: any = body or {}
    payload.reply_to = tostring(process.pid())
    local replies = process.listen("desktop.reply", {message = true})
    local sent, serr = process.send(tostring(desk.service), topic, payload)
    test.is_true(sent == true, "the command did not reach the compositor: " .. tostring(serr))
    local expiry = time.after("8s")
    local answer: any = {}
    while true do
        local picked = channel.select({replies:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then
            test.is_true(false, "no answer to " .. topic .. " (look at the compositor's screen)")
            break
        end
        local got: any = body_of(picked.value)
        if not got.unsolicited and (got.command == nil or got.command == topic) then
            answer = got
            break
        end
    end
    process.unlisten(replies)
    return answer
end

-- The listed window with this id, or nil; and the list itself.
local function listed(desk: any, id: any): (any, any)
    local listing: any = ask(desk, "desktop.list", {})
    for _, window in ipairs(listing.windows or {}) do
        if tostring(window.id) == tostring(id) then return window, listing end
    end
    return nil, listing
end

-- Wait until `check(window, listing)` holds, polling the list; seconds is the cap.
local function wait_for(desk: any, id: any, seconds: number, check: any): (any, any)
    local deadline = time.now():unix_nano() + math.floor(seconds * 1000000000)
    local window, listing = listed(desk, id)
    while time.now():unix_nano() < deadline do
        if check(window, listing) then return window, listing end
        pause("100ms")
        window, listing = listed(desk, id)
    end
    return window, listing
end

local function open(desk: any, spec: any): any
    local opened: any = ask(desk, "desktop.open", spec)
    test.is_true(opened.ok == true, "the window did not open: " .. tostring(opened.error))
    local id = opened.window and opened.window.id
    -- Ready: its terminal started, so it gets `close` rather than a kill.
    local window = wait_for(desk, id, 5, function(found: any) return found ~= nil and found.ready == true end)
    test.is_true(window ~= nil and window.ready == true, "the window never got ready")
    return id
end

local function define_tests()
    test.describe("Full-screen presentation",function()
        test.it("delivers interactive input, keeps the full viewport on resize and exits only on Esc",function()
            local desk=boot("chicago.tui_desktop.test.presentation.interactive")
            local parent=open(desk,{entry="app:painter_window"})
            local game=open(desk,{entry="app:interactive_presentation_window"})
            local full=listed(desk,game)
            test.is_true(full.presentation_interactive)
            test.eq(full.width,80);test.eq(full.height,24)
            desk.view:send({type="key",action="press",key_type="left",key="left"})
            desk.view:send({type="key",action="press",key_type="runes",key=" ",ctrl=false})
            desk.view:send({type="key",action="press",key_type="runes",key="q",ctrl=true})
            desk.view:send({type="mouse",action="press",button="left",x=20,y=10})
            desk.view:send({type="mouse",action="release",button="left",x=20,y=10})
            desk.view:send({type="mouse",action="motion",button="none",x=21,y=10})
            local seen=""
            for attempt=1,30 do
                local screen=ask(desk,"desktop.screen",{id=game})
                seen=table.concat(screen.rows or {},"\n")
                if seen:find("Keys: 3 Clicks: 1 At: 20,10",1,true) then break end
                pause("50ms")
            end
            test.is_true(seen:find("Keys: 3 Clicks: 1 At: 20,10",1,true)~=nil,seen)
            desk.view:resize(100,32)
            full=wait_for(desk,game,2,function(w) return w and w.width==100 end)
            test.eq(full.width,100);test.eq(full.height,32)
            desk.view:send({type="key",action="release",key_type="esc",key="esc"})
            pause("50ms");test.not_nil(listed(desk,game))
            desk.view:send({type="key",action="press",key_type="esc",key="esc"})
            local gone,after=wait_for(desk,game,2,function(w) return w==nil end)
            test.is_nil(gone);test.eq(after.focused,parent)
            test.not_nil(process.registry.lookup(desk.service))
            process.registry.unregister(tostring(desk.watcher))
            process.terminate(tostring(desk.pid))
        end)

        test.it("uses the whole cell-only viewport and restores the desktop on a key",function()
            local desk=boot("chicago.tui_desktop.test.presentation.cells","presentation_cells")
            local preview=open(desk,{entry="app:presentation_window"})
            local full,listing=listed(desk,preview)
            test.eq(full.width,80);test.eq(full.height,24);test.eq(full.x,1);test.eq(full.y,1)
            test.eq(listing.pixels,false)
            local screen=ask(desk,"desktop.screen",{id=preview})
            test.eq(#screen.rows,24,"the client includes the row normally occupied by the taskbar")
            desk.view:send({type="key",action="press",key_type="esc",key="esc"})
            local gone=wait_for(desk,preview,2,function(w) return w==nil end)
            test.is_nil(gone)
            process.registry.unregister(tostring(desk.watcher))
            process.terminate(tostring(desk.pid))
        end)
        test.it("uses every cell, follows resize, ignores opening release and dismisses input without closing its parent",function()
            local desk=boot("chicago.tui_desktop.test.presentation")
            local parent=open(desk,{entry="app:painter_window"})
            desk.view:send({type="mouse",action="motion",button="none",x=20,y=10})
            local preview=open(desk,{entry="app:presentation_window"})
            local full,listing=listed(desk,preview)
            test.eq(full.presentation,true);test.eq(full.x,1);test.eq(full.y,1)
            test.eq(full.width,80);test.eq(full.height,24);test.eq(listing.focused,preview)
            desk.view:send({type="mouse",action="release",button="left",x=20,y=10})
            desk.view:send({type="mouse",action="motion",button="none",x=20,y=10})
            pause("80ms")
            test.not_nil(listed(desk,preview),"opening release and unchanged pointer do not close preview")
            desk.view:resize(90,30)
            full=wait_for(desk,preview,2,function(w) return w and w.width==90 end)
            test.eq(full.width,90);test.eq(full.height,30)
            desk.view:send({type="mouse",action="motion",button="none",x=21,y=10})
            local gone,after=wait_for(desk,preview,2,function(w) return w==nil end)
            test.is_nil(gone);test.eq(after.focused,parent)
            local again=open(desk,{entry="app:presentation_window"})
            desk.view:send({type="key",action="release",key_type="runes",key="a"})
            pause("50ms");test.not_nil(listed(desk,again))
            desk.view:send({type="key",action="press",key_type="runes",key="q",ctrl=true})
            gone,after=wait_for(desk,again,2,function(w) return w==nil end)
            test.is_nil(gone);test.eq(after.focused,parent)
            test.not_nil(process.registry.lookup(desk.service),"dismissal consumes global shortcuts")
            process.registry.unregister(tostring(desk.watcher))
            process.terminate(tostring(desk.pid))
        end)
    end)
end
local run_cases=test.run_cases(define_tests)
return {run=function(options) return run_cases(options) end}
