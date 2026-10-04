--[[
Script: TaskChestNavigationController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/TaskChestNavigationController
Purpose: Task/chest page transitions and return state; no inventory or reward authority.
]]
local CinematicUiGate = require(script.Parent:WaitForChild("CinematicUiGate"))
local Navigation = {}
Navigation._pages = {}
Navigation._history = {}
Navigation._currentPage = nil
Navigation._serial = 0

function Navigation:Init(dependencies)
    self._pages = { Tasks = dependencies.TaskController, Chests = dependencies.ChestController }
    self._history = {}
    self._currentPage = nil
    self._serial += 1
    CinematicUiGate:CancelDeferred(self)
end

function Navigation:_hide(page, immediate)
    local controller = self._pages[page]
    if controller then controller:_setNavigationOpen(false, immediate) end
end

function Navigation:_show(page, context)
    local serial = self._serial
    local function show()
        if self._serial ~= serial or self._currentPage ~= page then return end
        local controller = self._pages[page]
        controller:_setNavigationOpen(true, false)
        if context and controller._restoreNavigationState then controller:_restoreNavigationState(context) end
    end
    if CinematicUiGate:IsBlocked() then CinematicUiGate:Defer(self, show) else show() end
end

-- HUD/external entries start a new route; in-panel links preserve the source.
function Navigation:Open(page)
    if not self._pages[page] then return false end
    self._serial += 1
    CinematicUiGate:CancelDeferred(self)
    for otherPage in pairs(self._pages) do
        if otherPage ~= page then self:_hide(otherPage, true) end
    end
    table.clear(self._history)
    self._currentPage = page
    self:_show(page)
    return true
end

function Navigation:Navigate(fromPage, toPage)
    if self._currentPage ~= fromPage or fromPage == toPage or not self._pages[toPage] then return false end
    self._serial += 1
    local source = self._pages[fromPage]
    table.insert(self._history, {
        page = fromPage,
        context = source._captureNavigationState and source:_captureNavigationState() or nil,
    })
    self:_hide(fromPage, true)
    self._currentPage = toPage
    self:_show(toPage)
    return true
end

function Navigation:Close(page)
    if self._currentPage ~= page then return false end
    self._serial += 1
    CinematicUiGate:CancelDeferred(self)
    local origin = table.remove(self._history)
    self:_hide(page, origin ~= nil)
    self._currentPage = origin and origin.page or nil
    if origin then self:_show(origin.page, origin.context) end
    return true
end

return Navigation
