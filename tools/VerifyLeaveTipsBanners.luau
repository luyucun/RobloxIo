-- V6.25: deployed source + detached formal GUI + fake menu/render signals, real TweenService.
-- No production Init, Playtest, real menu input, Remote, reward or DataStore calls.
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Studio Edit only")
assert(game.PlaceId == 73988417166286, "Wrong Place")
local HttpService = game:GetService("HttpService")
local sources = game.StarterPlayer.StarterPlayerScripts.Controllers
local referenceSource = nil -- Runner injects the read-only 加1陀螺 source for exact gradient comparison.
local results, warnings, verified = {}, {}, true
local controller, container, gate, hold
local function check(name, callback)
    local ok, failure = pcall(callback)
    table.insert(results, { name=name,passed=ok,detail=not ok and tostring(failure) or nil })
    if not ok then verified=false end
end
local function signal()
    local self = { handlers={} }
    function self:Connect(callback)
        local connection = { Connected=true,callback=callback }
        function connection:Disconnect() self.Connected=false end
        table.insert(self.handlers,connection)
        return connection
    end
    function self:Fire(...)
        for _, connection in ipairs(table.clone(self.handlers)) do
            if connection.Connected then connection.callback(...) end
        end
    end
    return self
end
local function fresh(module, overrides, extra)
    local env=setmetatable({script=module},{__index=getfenv()})
    env.require=function(dependency) return overrides and overrides[dependency.Name] or require(dependency) end
    env.warn=function(message) table.insert(warnings,tostring(message)) end
    for key,value in pairs(extra or {}) do env[key]=value end
    local chunk=assert(loadstring(module.Source,module.Name)); setfenv(chunk,env)
    return chunk()
end
local function near(a,b) return math.abs(a-b)<1e-4 end
local ok, failure=pcall(function()
    local formal=assert(game.StarterGui:FindFirstChild("LeaveTipsGui"))
    local originalText=game.StarterGui.Main.LeaveTips.Text.Text
    check("Formal template matches reference dimensions, anchors, layers and existing text",function()
        assert(formal.DisplayOrder==999 and formal.IgnoreGuiInset and not formal.ResetOnSpawn and not formal.Enabled)
        assert(formal.ZIndexBehavior==Enum.ZIndexBehavior.Global)
        for index,name in ipairs({"TopBanner","BottomBanner"}) do
            local banner=formal[name]; local text=banner.Text
            assert(banner.AnchorPoint==Vector2.new(0,index==1 and 0 or 1))
            assert(near(banner.Size.Y.Scale,0.1) and banner.BackgroundColor3==Color3.new(0,0,0) and banner.BackgroundTransparency==0)
            assert(not banner.Active and not text.Active and not text.Selectable)
            assert(text.Text==originalText and text.Font==Enum.Font.FredokaOne and text.TextScaled)
            assert(near(text.Size.Y.Scale,0.7) and text.AnchorPoint==Vector2.new(0.5,0.5) and text.BackgroundTransparency==1)
            assert(#text.UIGradient.Color.Keypoints==7)
        end
        assert(not game.StarterGui.Main.LeaveTips.Visible)
    end)
    container=Instance.new("Folder")
    local main=Instance.new("ScreenGui"); main.Name="Main"; main.Parent=container
    local legacy=game.StarterGui.Main.LeaveTips:Clone(); legacy.Visible=true; legacy.Parent=main
    local gui=formal:Clone(); gui.Parent=container
    local opened,closed,render,destroyed=signal(),signal(),signal(),signal()
    local menu={MenuIsOpen=false,MenuOpened=opened,MenuClosed=closed}
    local fakePlayer={FindFirstChild=function(_,name) return name=="PlayerGui" and container or nil end}
    local fakeClock=1.75
    gate=fresh(sources.CinematicUiGate)
    controller=fresh(sources.LeaveTipsController,{CinematicUiGate=gate},{
        game={GetService=function(_,name)
            if name=="GuiService" then return menu end
            if name=="RunService" then return {RenderStepped=render} end
            return game:GetService(name)
        end},
        os=setmetatable({clock=function() return fakeClock end},{__index=os}),
    })
    local dependencies={LocalPlayer=fakePlayer,RootScript={Destroying=destroyed}}
    controller:Init(dependencies)
    local top,bottom=gui.TopBanner,gui.BottomBanner
    local function shown()
        assert(gui.Enabled and near(top.Position.Y.Scale,0) and near(bottom.Position.Y.Scale,1))
        assert(controller._bannersVisible)
    end
    local function parked()
        assert(near(top.Position.Y.Scale,-0.11) and near(bottom.Position.Y.Scale,1.11))
    end
    check("Binding parks both banners before enabling and hides legacy tip",function()
        assert(gui.Enabled and not legacy.Visible and not controller._bannersVisible)
        parked()
    end)
    menu.MenuIsOpen=true; opened:Fire(); task.wait(0.5)
    check("Menu open really slides top down and bottom up to screen edges",shown)
    check("Gradient matches reference algorithm, flows and keeps same-color endpoints",function()
        assert(referenceSource,"Missing reference input")
        local implementation=assert(referenceSource:match("(local function applyRainbowPhase.-\nend)"))
        local referenceApply=assert(loadstring(implementation.."\nreturn applyRainbowPhase"))()
        local expected=Instance.new("UIGradient")
        render:Fire(1/30)
        referenceApply(expected,(fakeClock*0.12)%1)
        for _,banner in ipairs({top,bottom}) do
            local gradient=banner.Text.UIGradient
            assert(gradient.Color==expected.Color and gradient.Offset==Vector2.zero and gradient.Rotation==0)
            local keys=gradient.Color.Keypoints
            assert(keys[1].Value==keys[#keys].Value)
        end
        local oldColor=top.Text.UIGradient.Color
        fakeClock+=0.4; render:Fire(1/30)
        assert(top.Text.UIGradient.Color~=oldColor)
        expected:Destroy()
    end)
    menu.MenuIsOpen=false; closed:Fire(); task.wait(0.5)
    check("Menu close slides both fully offscreen and stops hidden rainbow",function()
        parked(); assert(not controller._bannersVisible)
        local before=top.Text.UIGradient.Color
        fakeClock+=0.5; render:Fire(1)
        assert(top.Text.UIGradient.Color==before)
    end)
    menu.MenuIsOpen=true; task.wait(0.65)
    check("Property-only opening is recovered by edge polling",shown)
    menu.MenuIsOpen=false; task.wait(0.65)
    check("Property-only closing is recovered by edge polling",function() parked(); assert(not controller._bannersVisible) end)
    opened:Fire(); task.wait(0.75)
    check("Stale false property does not undo an earlier open event",shown)
    closed:Fire(); task.wait(0.06); opened:Fire(); task.wait(0.5)
    check("Rapid close/reopen cancels old tweens and stale hide callback",shown)
    local active=table.clone(controller._activeTweens)
    opened:Fire()
    check("Duplicate events do not restart an already-open slide",function()
        assert(controller._activeTweens[1]==active[1] and controller._activeTweens[2]==active[2])
    end)
    hold=gate:Acquire("ESC-verification")
    check("Cinematic gate hides/parks banners while retaining menu intent",function()
        assert(not gui.Enabled and not controller._bannersVisible and controller._menuOpen)
        parked()
    end)
    gate:Release(hold); hold=nil; task.wait(0.5)
    check("Gate release restores still-open menu even if property remains stale",shown)
    hold=gate:Acquire("ESC-close-check")
    closed:Fire(); gate:Release(hold); hold=nil; task.wait(0.5)
    check("Closing during cinematic does not resurrect banners afterwards",function() parked(); assert(not controller._bannersVisible) end)
    local oldTopAnchor=top.AnchorPoint; local oldBottomAnchor=bottom.AnchorPoint
    local oldTopSize=top.Size; local oldBottomSize=bottom.Size
    top.AnchorPoint=Vector2.new(0,0.5); bottom.AnchorPoint=Vector2.new(0,0)
    top.Size=UDim2.fromScale(1,0.13); bottom.Size=UDim2.fromScale(1,0.13)
    opened:Fire(); task.wait(0.5)
    check("Changed anchor/height still shows both banners completely onscreen",function()
        local topEdge=top.Position.Y.Scale-top.AnchorPoint.Y*top.Size.Y.Scale
        local bottomEdge=bottom.Position.Y.Scale-bottom.AnchorPoint.Y*bottom.Size.Y.Scale
        assert(near(topEdge,0) and near(bottomEdge+bottom.Size.Y.Scale,1))
    end)
    closed:Fire(); task.wait(0.5)
    check("Changed anchor/height still parks both completely offscreen",function()
        assert(top.Position.Y.Scale+(1-top.AnchorPoint.Y)*top.Size.Y.Scale<0)
        assert(bottom.Position.Y.Scale-bottom.AnchorPoint.Y*bottom.Size.Y.Scale>1)
    end)
    top.AnchorPoint=oldTopAnchor; bottom.AnchorPoint=oldBottomAnchor
    top.Size=oldTopSize; bottom.Size=oldBottomSize
    opened:Fire(); task.wait(0.5)
    local oldConnections=table.clone(controller._uiConnections)
    local oldGui=gui
    oldGui.Parent=nil
    local replacement=formal:Clone(); replacement.Parent=container
    task.wait(0.6)
    gui=replacement; top=gui.TopBanner; bottom=gui.BottomBanner
    check("Replacing GUI cancels old bindings and restores current menu intent",function()
        assert(controller._gui==gui and not oldGui.Enabled)
        for _,connection in ipairs(oldConnections) do assert(not connection.Connected) end
        shown()
    end)
    oldGui:Destroy()
    controller:Init(dependencies); task.wait(0.1)
    check("Reinitialization resets listeners/intent from current menu property",function()
        assert(not controller._menuOpen and not controller._bannersVisible and #controller._connections==6)
        parked()
    end)
    gui:Destroy()
    controller:Destroy()
    controller:Init(dependencies)
    opened:Fire()
    local late=formal:Clone(); late.Parent=container; task.wait(0.6)
    gui=late; top=gui.TopBanner; bottom=gui.BottomBanner
    check("Late template binds and honors menu event received before UI arrival",shown)
    local connections=table.clone(controller._connections)
    local uiConnections=table.clone(controller._uiConnections)
    destroyed:Fire(); task.wait(0.3)
    check("Root destruction disconnects listeners and stops both render and poll work",function()
        assert(not gui.Enabled and not controller._gui and not controller._bannersVisible)
        for _,connection in ipairs(connections) do assert(not connection.Connected) end
        for _,connection in ipairs(uiConnections) do assert(not connection.Connected) end
        local color=top.Text.UIGradient.Color
        opened:Fire(); fakeClock+=1; render:Fire(1); task.wait(0.3)
        assert(not gui.Enabled and top.Text.UIGradient.Color==color)
    end)
end)
if not ok then verified=false; table.insert(results,{name="Setup/execution",passed=false,detail=tostring(failure)}) end
if hold and gate then gate:Release(hold) end
if controller then controller:Destroy() end
if container then container:Destroy() end
return HttpService:JSONEncode({verified=verified,results=results,warnings=warnings,
    excluded={"Real ESC/mobile menu input and layering above Roblox CoreGui require a user-run Playtest."}})
