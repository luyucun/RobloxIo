-- Isolated input/lifecycle regression; no production Init, Remote calls or players.
assert(game.PlaceId == 73988417166286 and game:GetService("RunService"):IsStudio())
local passed, failed = {}, {}
local now = 100
local deferred, delayed = {}, {}
local function signal()
    local s = { listeners = {} }
    function s:Connect(callback)
        local connection = { Connected = true }
        function connection:Disconnect() self.Connected = false end
        table.insert(self.listeners, { connection = connection, callback = callback })
        return connection
    end
    function s:Fire(...)
        for _, entry in ipairs(table.clone(self.listeners)) do
            if entry.connection.Connected then entry.callback(...) end
        end
    end
    return s
end
local function node(name, class)
    local n = { Name = name, ClassName = class, children = {}, Active = true, Interactable = true,
        Visible = true, ChildAdded = signal(), DescendantAdded = signal(), AncestryChanged = signal(),
        DescendantRemoving = signal(), Activated = signal() }
    function n:IsA(kind)
        return kind == self.ClassName or (kind == "GuiButton" and self.ClassName == "TextButton")
            or (kind == "GuiObject" and self.ClassName ~= "PlayerGui" and self.ClassName ~= "ScreenGui")
    end
    function n:FindFirstChild(childName)
        for _, child in ipairs(self.children) do if child.Name == childName then return child end end
    end
    n.WaitForChild = n.FindFirstChild
    function n:GetChildren() return table.clone(self.children) end
    function n:GetDescendants()
        local result = {}
        for _, child in ipairs(self.children) do
            table.insert(result, child)
            for _, descendant in ipairs(child:GetDescendants()) do table.insert(result, descendant) end
        end
        return result
    end
    function n:IsDescendantOf(ancestor)
        local current = self.Parent
        while current do if current == ancestor then return true end current = current.Parent end
        return false
    end
    return n
end
local function attach(parent, child)
    child.Parent = parent; table.insert(parent.children, child)
    parent.ChildAdded:Fire(child)
    local ancestor = parent
    while ancestor do
        ancestor.DescendantAdded:Fire(child)
        for _, descendant in ipairs(child:GetDescendants()) do ancestor.DescendantAdded:Fire(descendant) end
        ancestor = ancestor.Parent
    end
    child.AncestryChanged:Fire(child, parent)
    for _, descendant in ipairs(child:GetDescendants()) do descendant.AncestryChanged:Fire(descendant, descendant.Parent) end
end
local function detach(child)
    local parent = child.Parent
    if not parent then return end
    local ancestor = parent
    while ancestor do ancestor.DescendantRemoving:Fire(child); ancestor = ancestor.Parent end
    table.remove(parent.children, table.find(parent.children, child)); child.Parent = nil
    child.AncestryChanged:Fire(child, nil)
    for _, descendant in ipairs(child:GetDescendants()) do descendant.AncestryChanged:Fire(descendant, descendant.Parent) end
end
local function flush()
    for _ = 1, 10 do
        if #deferred == 0 then return end
        local work = table.clone(deferred); table.clear(deferred)
        for _, callback in ipairs(work) do callback() end
    end
    error("Unbounded UI retry")
end
local action, focused
local userInput = { TouchEnabled = false, GetFocusedTextBox = function() return focused end }
local fakeGame = {}
function fakeGame:GetService(name)
    if name == "UserInputService" then return userInput end
    if name == "ContextActionService" then
        return { UnbindAction = function() action = nil end,
            BindActionAtPriority = function(_, _, callback) action = callback end }
    end
    if name == "TweenService" then
        return { Create = function(_, target, _, goals)
            return { Completed = signal(), Play = function() end, Cancel = function() end,
                Target = target, Goals = goals }
        end }
    end
    return game:GetService(name)
end
local source = __flashSource or game.StarterPlayer.StarterPlayerScripts.Controllers.FlashController.Source
local chunk, err = loadstring(source, "=FlashControllerInputFixture"); assert(chunk, err)
setfenv(chunk, setmetatable({ game = fakeGame,
    os = setmetatable({ clock = function() return now end }, { __index = os }),
    task = { defer = function(callback) table.insert(deferred, callback) end,
        delay = function(seconds, callback) table.insert(delayed, { seconds = seconds, callback = callback }) end },
}, { __index = getfenv() }))
local Flash = chunk()
local function buildMain()
    local main, flash, info = node("Main", "ScreenGui"), node("Flash", "Frame"), node("Info", "Frame")
    attach(main, flash); attach(flash, info)
    for _, pair in ipairs({ {"CooldownMask", "Frame"}, {"Icon", "ImageLabel"},
        {"Icon02", "ImageLabel"}, {"TextLabel", "TextLabel"} }) do attach(info, node(pair[1], pair[2])) end
    local button = node("TextButton", "TextButton"); attach(info, button)
    return main, info, button
end
local function fixture(options)
    table.clear(deferred); table.clear(delayed); focused = nil; userInput.TouchEnabled = false
    local c = table.clone(Flash)
    for key, value in pairs(c) do if type(value) == "table" and key:sub(1,1) == "_" then c[key] = {} end end
    local gui = node("PlayerGui", "PlayerGui")
    local main, info, button = buildMain()
    if options == "late-button" then detach(button) end
    if options ~= "late-main" then attach(gui, main) end
    local humanoid = { Health = 100, MoveDirection = Vector3.new(1,0,0) }
    local player = { Character = { FindFirstChildOfClass = function() return humanoid end },
        FindFirstChild = function(_, name) return name == "PlayerGui" and gui or nil end }
    local f = { c = c, gui = gui, main = main, info = info, button = button,
        humanoid = humanoid, requests = 0, suspensions = 0, requestedWhileMoving = false, modal = false }
    c._bindRemotes = function(self)
        self._requestFlashEvent = { FireServer = function(_, ...)
            assert(select("#", ...) == 0, "Flash must remain an intent-only request")
            f.requests += 1; f.requestedWhileMoving = humanoid.MoveDirection.Magnitude > 0
        end }
        return true
    end
    c._playPredictedFlash = function() end
    c:Init({ LocalPlayer = player, ModalUiController = { IsAnyOpen = function() return f.modal end },
        AutoBattleController = { SuspendForFlash = function(_, duration)
            assert(duration > 0); f.suspensions += 1; humanoid.MoveDirection = Vector3.zero
        end } })
    c._latestState = { alive = true, isInArena = true }; c:_updateVisualState()
    return f
end
local function test(name, callback)
    now += 20
    local ok, problem = pcall(callback)
    if ok then table.insert(passed, name) else table.insert(failed, { name = name, error = tostring(problem) }) end
end
test("Late TextButton binds even when Main already exists", function()
    local f = fixture("late-button")
    attach(f.info, f.button); flush(); f.button.Activated:Fire()
    assert(f.requests == 1, "Late button never received Activated handler")
end)
test("Main arriving after Init binds once its descendants arrive", function()
    local f = fixture("late-main"); attach(f.gui, f.main); flush(); f.button.Activated:Fire()
    assert(f.requests == 1)
end)
test("Main replacement disconnects the old button and binds the new one", function()
    local f = fixture(); detach(f.main)
    local main, _, button = buildMain(); attach(f.gui, main); flush()
    f.button.Activated:Fire(); assert(f.requests == 0, "Old detached button remains bound")
    button.Activated:Fire(); assert(f.requests == 1, "Replacement button is unbound")
end)
test("Repeated UI binds do not duplicate requests", function()
    local f = fixture(); f.c:_bindUi(); f.c:_bindUi()
    f.button.Activated:Fire(); assert(f.requests == 1)
end)
test("Button replacement inside the existing Info is rebound", function()
    local f = fixture(); detach(f.button)
    local button = node("TextButton", "TextButton"); attach(f.info, button); flush()
    f.button.Activated:Fire(); assert(f.requests == 0)
    button.Activated:Fire(); assert(f.requests == 1)
end)
test("Late visual descendants are picked up without duplicating input", function()
    local f = fixture(); local old = f.info:FindFirstChild("Icon"); detach(old)
    local icon = node("Icon", "ImageLabel"); attach(f.info, icon); flush()
    assert(f.c._icon == icon)
    f.button.Activated:Fire(); assert(f.requests == 1)
end)
test("HUD replacement preserves pending request and remaining cooldown", function()
    local f = fixture(); f.c:_startCooldown(8); now += 3; f.c._requestPending = true
    detach(f.main); local main, info, button = buildMain(); attach(f.gui, main); flush()
    assert(f.c._button == button and f.c._requestPending)
    assert(math.abs(f.c._cooldownEndsAt - (now + 5)) < 1e-6)
    assert(info:FindFirstChild("CooldownMask").Visible)
    button.Activated:Fire(); assert(f.requests == 0)
end)
for _, inputType in ipairs({ Enum.UserInputType.MouseButton1, Enum.UserInputType.Touch }) do
    test(tostring(inputType).." Activated sends an intent without stopping auto movement first", function()
        local f = fixture(); userInput.TouchEnabled = inputType == Enum.UserInputType.Touch
        f.button.Activated:Fire({ UserInputType = inputType })
        assert(f.requests == 1); assert(f.suspensions == 0, "Auto stopped before authority approval")
        assert(f.requestedWhileMoving)
        f.c:_handleFeedback({ eventType = "Started", cooldownSeconds = 8, durationSeconds = .3,
            requestId = "approved", targetPosition = Vector3.new(24,0,0) })
        assert(f.suspensions == 1, "Approved Flash did not suspend auto")
        assert(f.humanoid.MoveDirection == Vector3.zero)
    end)
end
test("Q and gamepad Begin share the request path; End does not request", function()
    local f = fixture()
    assert(action("IOFlash", Enum.UserInputState.End) == Enum.ContextActionResult.Pass)
    assert(f.requests == 0)
    assert(action("IOFlash", Enum.UserInputState.Begin) == Enum.ContextActionResult.Sink)
    assert(f.requests == 1 and f.requestedWhileMoving and f.suspensions == 0)
end)
test("Rejected Flash does not interrupt auto movement or start cooldown", function()
    local f = fixture(); f.button.Activated:Fire()
    f.c:_handleFeedback({ eventType = "Rejected", reason = "Blocked" })
    assert(f.suspensions == 0 and f.humanoid.MoveDirection.Magnitude > 0)
    assert(not f.c._requestPending and not f.c:_isCoolingDown())
end)
test("Pending request ignores repeated button and Q input", function()
    local f = fixture(); f.button.Activated:Fire(); f.button.Activated:Fire()
    action("IOFlash", Enum.UserInputState.Begin)
    assert(f.requests == 1)
end)
for _, mode in ipairs({ "dead", "lobby", "idle", "modal", "textbox", "cooldown" }) do
    test(mode.." blocks button and keyboard requests", function()
        local f = fixture()
        if mode == "dead" then f.c._latestState.alive = false
        elseif mode == "lobby" then f.c._latestState.isInArena = false
        elseif mode == "idle" then f.humanoid.MoveDirection = Vector3.zero
        elseif mode == "modal" then f.modal = true
        elseif mode == "textbox" then focused = {}
        elseif mode == "cooldown" then f.c._cooldownEndsAt = now + 8 end
        f.button.Activated:Fire(); action("IOFlash", Enum.UserInputState.Begin)
        assert(f.requests == 0 and f.suspensions == 0)
    end)
end
return game:GetService("HttpService"):JSONEncode({ passCount = #passed, failCount = #failed, passed = passed, failed = failed })
