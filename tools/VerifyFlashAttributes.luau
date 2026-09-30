-- Script: VerifyFlashAttributes | Type: isolated Studio Edit regression tool
-- Studio path: project MCP execute_luau; no Init, real player, purchase or DataStore.
assert(game.PlaceId == 73988417166286)
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning())
local HttpService = game:GetService("HttpService")
local passed, failed = {}, {}
local clockNow = 100
local delayed = {}
local function forbidden() error("External side effect attempted by isolated verification") end
local actors = {
    IsPlayer = function(a) return type(a) == "table" and a.UserId ~= nil end,
    IsBot = function() return false end,
    GetActorId = function(a) return a.UserId end,
    GetActorKind = function() return "Player" end,
    GetCombatUserId = function(a) return a.UserId end,
    GetRootPart = function(a) return a.root end,
    GetHumanoid = function(a) return a.humanoid end,
    GetCharacter = function(a) return a.character end,
}
local fakeGame = {}
local tweens = {}
function fakeGame:GetService(name)
    if name == "Players" then
        return {GetPlayers=function() return {} end, GetPlayerByUserId=function() return nil end}
    elseif name == "MarketplaceService" or name == "DataStoreService" then
        return setmetatable({}, {__index=function() return forbidden end})
    elseif name == "TweenService" then
        return {Create=function(_,target,info,goals)
            local t={target=target,info=info,goals=goals,Play=function() end,Cancel=function() end,
                Completed={Connect=function() return {Disconnect=function() end} end}}
            table.insert(tweens,t)
            return t
        end}
    end
    return game:GetService(name)
end
local modules={}
local loadModule
loadModule=function(instance)
    if instance.Name == "ActorUtils" then return actors end
    if modules[instance] ~= nil then return modules[instance] end
    local chunk,err=loadstring(instance.Source,"="..instance.Name)
    assert(chunk,err)
    setfenv(chunk,setmetatable({script=instance,game=fakeGame,require=loadModule,
        os=setmetatable({clock=function() return clockNow end},{__index=os}),
        task={delay=function(seconds,callback) table.insert(delayed,{seconds=seconds,callback=callback}) end,
            spawn=forbidden,defer=forbidden,wait=forbidden},
    },{__index=getfenv()}))
    modules[instance]=chunk()
    return modules[instance]
end
local shared=game.ReplicatedStorage.Shared
local services=game.ServerScriptService.Services
local controllers=game.StarterPlayer.StarterPlayerScripts.Controllers
local Config=loadModule(shared.AttributeConfig)
local GameConfig=loadModule(shared.GameConfig)
local PlayerState=loadModule(services.PlayerStateService)
local Flash=loadModule(services.FlashService)
local Upgrade=loadModule(controllers.AttributeUpgradeController)
local Caps=loadModule(controllers.AttributeCapUpgradeController)
local FlashClient=loadModule(controllers.FlashController)
local Rebirth=loadModule(services.RebirthService)
local CapService=loadModule(services.AttributeCapUpgradeService)
local function eq(a,b,label) assert(a==b,(label or "value")..": "..tostring(a).." ~= "..tostring(b)) end
local function close(a,b,label) assert(math.abs(a-b)<1e-6,(label or "value")..": "..tostring(a).." ~= "..tostring(b)) end
local function vector(a,b) close((a-b).Magnitude,0,"vector") end
local function test(name,callback)
    clockNow+=20
    table.clear(delayed)
    local ok,err=pcall(callback)
    if ok then table.insert(passed,name) else table.insert(failed,{name=name,error=tostring(err)}) end
end
local function cloneService(module)
    local result=table.clone(module)
    for key,value in pairs(result) do if type(value)=="table" and key:sub(1,1)=="_" then result[key]={} end end
    return result
end
local function fixture()
    local p={UserId=91614,Name="FlashVerification",Parent=true}
    local ps=cloneService(PlayerState)
    for _,name in ipairs({"_syncLeaderstats","SyncHumanoidMovement","SyncCharacterState","UpdateOverheadHealthBar","CheckTitleUnlocks","RefreshOnlineTime","PushState"}) do ps[name]=function() end end
    local state=ps:_createDefaultState(p)
    ps._statesByActorId[p.UserId]=state
    state.Alive=true; state.IsInArena=true; state.SkillPoints=30; state.Diamonds=10000
    p.root={Position=Vector3.zero,AssemblyLinearVelocity=Vector3.zero,AssemblyAngularVelocity=Vector3.zero}
    p.humanoid={Health=100,MoveDirection=Vector3.new(1,0,0)}
    p.character={PivotTo=function(_,cframe) p.root.Position=cframe.Position end}
    local flash=cloneService(Flash)
    flash._playerStateService=ps
    flash._arenaService={ClampPositionInsideBattle=function(_,pos) return pos end,IsPositionInsideBattle=function() return true end}
    flash._getBlockingRaycast=function() return nil end
    flash._playAnimation=function() end
    local feedback={}
    flash._flashFeedbackEvent={FireClient=function(_,_,payload) table.insert(feedback,payload) end}
    return {p=p,ps=ps,state=state,flash=flash,feedback=feedback}
end
local function fullCaps(f)
    f.state.AttributeCaps.FlashCooldown=10
    f.state.AttributeCaps.FlashDistance=10
end

test("Eight active attributes; legacy Damage/MoveSpeed stay disabled",function()
    local count=0
    for _,key in ipairs(Config.Order) do if not Config.IsProgressionDisabled(key) then count+=1 end end
    eq(count,8)
    assert(Config.IsProgressionDisabled("Damage") and Config.IsProgressionDisabled("MoveSpeed"))
    for _,key in ipairs({"FlashCooldown","FlashDistance"}) do eq(Config.GetMaxCap(key),10);eq(Config.GetDefinition(key).InitialCap,8) end
end)
test("All eleven levels have distinct requested values and independent effects",function()
    local cds={8,7.6,7.2,6.8,6.4,6,5.6,5.2,4.8,4.4,4}
    local distances={24,27,30,33,36,39,42,45,48,51,54}
    for level=0,10 do
        local stats=Config.CalculateFinalStats({FlashCooldown=level,FlashDistance=10-level},{FlashCooldown=10,FlashDistance=10})
        close(stats.FlashCooldownSeconds,cds[level+1])
        close(stats.FlashDistanceStuds,distances[11-level])
    end
    close(GameConfig.FLASH.DurationSeconds,0.3)
end)
test("Missing, negative and over-cap archive fields normalize safely",function()
    local zero=Config.CalculateFinalStats(nil,nil)
    close(zero.FlashCooldownSeconds,8);close(zero.FlashDistanceStuds,24)
    local capped=Config.CalculateFinalStats({FlashCooldown=999,FlashDistance=999},{FlashCooldown=999,FlashDistance=999})
    close(capped.FlashCooldownSeconds,4);close(capped.FlashDistanceStuds,54)
    local negative=Config.CalculateFinalStats({FlashCooldown=-3,FlashDistance=-9},{})
    close(negative.FlashCooldownSeconds,8);close(negative.FlashDistanceStuds,24)
end)
test("Legacy Damage/MoveSpeed caps do not become Flash entitlements",function()
    local f=fixture()
    f.state.AttributeLevels={Damage=4,MoveSpeed=3}
    f.state.AttributeCaps={Damage=40,MoveSpeed=40}
    f.ps:_normalizeAttributeState(f.state)
    eq(f.state.AttributeLevels.FlashCooldown,0);eq(f.state.AttributeLevels.FlashDistance,0)
    eq(f.state.AttributeCaps.FlashCooldown,8);eq(f.state.AttributeCaps.FlashDistance,8)
    eq(f.state.SkillPoints,37)
    f.ps:_normalizeAttributeState(f.state);eq(f.state.SkillPoints,37)
end)
for _,key in ipairs({"FlashCooldown","FlashDistance"}) do
    test(key.." spends points, stops at 8, resumes at 9/10 and refuses 11",function()
        local f=fixture()
        for _=1,8 do assert(f.ps:TryUpgradeAttribute(f.p,key)) end
        eq(f.state.SkillPoints,22);eq(f.state.AttributeLevels[key],8)
        eq(f.ps:TryUpgradeAttribute(f.p,key),false);eq(f.state.SkillPoints,22)
        assert(f.ps:TryUpgradeAttributeCapWithDiamonds(f.p,key));eq(f.state.AttributeCaps[key],9);eq(f.state.Diamonds,9000)
        assert(f.ps:TryUpgradeAttribute(f.p,key))
        assert(f.ps:TryUpgradeAttributeCapWithDiamonds(f.p,key));eq(f.state.AttributeCaps[key],10);eq(f.state.Diamonds,6500)
        assert(f.ps:TryUpgradeAttribute(f.p,key));eq(f.state.SkillPoints,20)
        eq(f.ps:TryUpgradeAttribute(f.p,key),false)
        eq(f.ps:TryUpgradeAttributeCapWithDiamonds(f.p,key),false)
        eq(f.state.AttributeLevels[key],10);eq(f.state.SkillPoints,20);eq(f.state.Diamonds,6500)
    end)
    test(key.." Robux cap lookup/intent targets only this attribute and stops at 10",function()
        local f=fixture()
        local svc=cloneService(CapService);svc._playerStateService=f.ps
        local product=Config.GetCapUpgradeProduct(key,8)
        eq(product.ProductId,3603550266)
        svc:_recordRobuxPurchaseIntent(f.p,key,product.ProductId)
        eq(svc:_consumeRobuxPurchaseIntent(f.p,product.ProductId),key)
        eq(svc:_consumeRobuxPurchaseIntent(f.p,product.ProductId),nil)
        assert(f.ps:GrantAttributeCapProduct(f.p,key));eq(f.state.AttributeCaps[key],9)
        eq(Config.GetCapUpgradeProduct(key,9).ProductId,3603550309)
        assert(f.ps:GrantAttributeCapProduct(f.p,key));eq(f.state.AttributeCaps[key],10)
        eq(Config.GetCapUpgradeProduct(key,10),nil)
        local info=Config.GetCapUpgradeInfo(key,10)
        assert(info.IsMax and not info.RobuxEnabled and info.GemCost==nil)
    end)
end
test("No points, lobby and dead states cannot upgrade",function()
    local f=fixture()
    f.state.SkillPoints=0;eq(f.ps:TryUpgradeAttribute(f.p,"FlashDistance"),false)
    f.state.SkillPoints=5;f.state.IsInArena=false;eq(f.ps:TryUpgradeAttribute(f.p,"FlashCooldown"),false)
    f.state.IsInArena=true;f.state.Alive=false;eq(f.ps:TryUpgradeAttribute(f.p,"FlashCooldown"),false)
    eq(f.state.SkillPoints,5)
end)
test("State payload, combat snapshot and reset preserve correct caps",function()
    local f=fixture();fullCaps(f)
    f.state.AttributeLevels.FlashCooldown=10;f.state.AttributeLevels.FlashDistance=9
    local payload=f.ps:BuildAttributeStatePayload(f.p)
    close(payload.finalStats.FlashCooldownSeconds,4);close(payload.finalStats.FlashDistanceStuds,51)
    local snap=f.ps:BuildAttributeSnapshot(f.p)
    f.ps:_resetAttributeProgress(f.state)
    eq(f.state.AttributeLevels.FlashCooldown,0);eq(f.state.AttributeCaps.FlashCooldown,10)
    f.ps:_applyAttributeSnapshot(f.state,snap)
    eq(f.state.AttributeLevels.FlashCooldown,10);eq(f.state.AttributeLevels.FlashDistance,9)
    close(f.ps:GetFlashCooldownSeconds(f.p),4);close(f.ps:GetFlashDistanceStuds(f.p),51)
end)
test("Persistent save/load round-trip keeps the two caps",function()
    local f=fixture();fullCaps(f)
    local rb=cloneService(Rebirth)
    rb._processedPurchaseIdsByPlayerId={}
    rb._playerStateService=f.ps;rb._loadStateByUserId[f.p.UserId]="Loaded"
    rb._dataStore={}
    local saved=rb:_buildSavePayload(f.p,{includeCombatSnapshot=false})
    eq(saved.attributeCaps.FlashCooldown,10);eq(saved.attributeCaps.FlashDistance,10)
    local second=fixture()
    local load=cloneService(Rebirth)
    load._processedPurchaseIdsByPlayerId={}
    load._playerStateService=second.ps
    load._dataStore={GetAsync=function() return saved end}
    load:_loadPlayer(second.p)
    eq(second.state.AttributeCaps.FlashCooldown,10);eq(second.state.AttributeCaps.FlashDistance,10)
end)
test("Base and upgraded Flash use player attributes in authority and feedback",function()
    for _,level in ipairs({0,10}) do
        local f=fixture();fullCaps(f)
        f.state.AttributeLevels.FlashCooldown=level;f.state.AttributeLevels.FlashDistance=level
        f.flash:_handleRequest(f.p)
        local payload=f.feedback[#f.feedback]
        eq(payload.eventType,"Started")
        local cd=level==0 and 8 or 4;local distance=level==0 and 24 or 54
        close(payload.cooldownSeconds,cd);close(payload.requestedDistanceStuds,distance)
        vector(payload.targetPosition,Vector3.new(distance,0,0))
        close(f.flash._cooldownEndsByUserId[f.p.UserId],clockNow+cd)
    end
end)
test("Upgrade during cooldown does not reset or shorten an already started Flash",function()
    local f=fixture();fullCaps(f)
    f.flash:_handleRequest(f.p)
    local request=f.feedback[1]
    f.state.AttributeLevels.FlashCooldown=10;f.state.AttributeLevels.FlashDistance=10
    clockNow+=0.3
    assert(f.flash:_completeFlash(f.p,request.requestId))
    vector(f.p.root.Position,Vector3.new(24,0,0))
    f.flash:_handleRequest(f.p)
    eq(f.feedback[#f.feedback].reason,"Cooldown")
    close(f.feedback[#f.feedback].cooldownRemainingSeconds,7.7)
    clockNow+=7.7
    f.flash:_handleRequest(f.p)
    close(f.feedback[#f.feedback].cooldownSeconds,4)
    close(f.feedback[#f.feedback].requestedDistanceStuds,54)
end)
test("Flash rejects nonbattle, dead, idle and fully blocked requests without a cooldown",function()
    for _,mode in ipairs({"lobby","dead","idle","blocked"}) do
        local f=fixture()
        if mode=="lobby" then f.state.IsInArena=false
        elseif mode=="dead" then f.state.Alive=false
        elseif mode=="idle" then f.p.humanoid.MoveDirection=Vector3.zero
        else f.flash._getReachableTarget=function() return Vector3.zero,0 end end
        f.flash:_handleRequest(f.p)
        eq(f.feedback[#f.feedback].eventType,"Rejected")
        eq(f.flash._cooldownEndsByUserId[f.p.UserId],nil)
    end
end)
test("Wall stops a max-distance Flash before the obstacle",function()
    local f=fixture();fullCaps(f);f.state.AttributeLevels.FlashDistance=10
    f.flash._getBlockingRaycast=function() return {Distance=12} end
    f.flash:_handleRequest(f.p)
    close(f.feedback[1].travelDistanceStuds,11.65)
    vector(f.feedback[1].targetPosition,Vector3.new(11.65,0,0))
end)
test("Boundary clamp and wall retreat use the same direction",function()
    local f=fixture()
    f.flash._arenaService.ClampPositionInsideBattle=function(_,pos) return Vector3.new(math.min(10,pos.X),pos.Y,math.min(50,pos.Z)) end
    local direction=Vector3.new(1,0,1).Unit
    local rayDirection
    f.flash._getBlockingRaycast=function(_,_,delta) rayDirection=delta.Unit;return {Distance=5} end
    local pos=f.flash:_getReachableTarget(Vector3.zero,direction,nil,{DistanceStuds=54,CollisionPaddingStuds=.35})
    vector(pos,rayDirection*4.65)
    assert(pos.X<=10)
end)
test("A stale completion or death cannot teleport the player",function()
    local f=fixture();f.flash:_handleRequest(f.p)
    eq(f.flash:_completeFlash(f.p,"old-request"),false)
    vector(f.p.root.Position,Vector3.zero)
    clockNow+=1;f.state.Alive=false
    eq(f.flash:_completeFlash(f.p,f.feedback[1].requestId),false)
    vector(f.p.root.Position,Vector3.zero)
end)
test("Client cooldown mask uses the server's 8s/4s and approved target",function()
    local c=cloneService(FlashClient)
    c._updateVisualState=function() end
    local targetSeen
    c._playPredictedFlash=function(_,target) targetSeen=target end
    for _,seconds in ipairs({8,4}) do
        c:_handleFeedback({eventType="Started",cooldownSeconds=seconds,targetPosition=Vector3.new(54,0,0),durationSeconds=.3,requestId="test"})
        close(c._cooldownEndsAt,clockNow+seconds)
        vector(targetSeen,Vector3.new(54,0,0))
    end
end)

local fixtureFolder=Instance.new("Folder")
fixtureFolder.Name="__FlashAttributeVerification"
fixtureFolder.Parent=game.ServerStorage
local grid=game.StarterGui.Main.AttributeUpgrade.Window.Content.StatsGrid:Clone();grid.Parent=fixtureFolder
local list=game.StarterGui.Main.AttributeUpgradeOut.Window.StatsList:Clone();list.Parent=fixtureFolder
local up=cloneService(Upgrade)
up._isBattleReady=function() return true end
local capUi=cloneService(Caps)
capUi._robuxPriceByProductId={[3603550266]=19,[3603550309]=29}
for _,key in ipairs({"FlashCooldown","FlashDistance"}) do
    test(key.." binds original-style card, shows current value, 10 segments and disabled MAX",function()
        local card=up:_bindCard(grid,key);assert(card)
        local f=fixture();fullCaps(f);f.state.AttributeLevels[key]=10
        up:_applyCard(key,card,f.ps:BuildAttributeStatePayload(f.p))
        eq(card.Level.Text,"Lv.10/10");eq(card.AddButtonLabel.Text,"MAX");eq(card.AddButton.Active,false)
        eq(card.Effect.Text,key=="FlashCooldown" and "4.0s" or "54 studs")
        local segments=0
        for _,node in ipairs(card.Progress:GetChildren()) do if node:IsA("Frame") and node.Visible then segments+=1 end end
        eq(segments,10)
    end)
    test(key.." binds cap row, prices 8 to 9, stops both purchase buttons at 10",function()
        local row=capUi:_bindRow(list,key);assert(row)
        local caps=Config.BuildDefaultCaps()
        capUi:_applyRow(key,row,caps,10000)
        eq(row.CurrentCap.Text,"8");eq(row.NextCap.Text,"9")
        assert(row.GemButton.Active and row.RobuxButton.Active)
        caps[key]=10;capUi:_applyRow(key,row,caps,10000)
        eq(row.NextCap.Text,"MAX");eq(row.GemPrice.Text,"MAX");eq(row.RobuxPrice.Text,"MAX")
        assert(not row.GemButton.Active and not row.RobuxButton.Active)
    end)
end
test("Formal grid contains exactly eight visible original-style attribute cards",function()
    local visible=0
    for _,node in ipairs(grid:GetChildren()) do if node:IsA("Frame") and node.Visible then visible+=1 end end
    eq(visible,8)
    eq(grid.WeaponDamage.Visible,false);eq(grid.MoveSpeed.Visible,false)
end)
for _,controller in ipairs({up,capUi}) do
    for _,connection in ipairs(controller._uiConnections) do connection:Disconnect() end
end
fixtureFolder:Destroy()
return HttpService:JSONEncode({passed=#passed,failed=#failed,tests=passed,failures=failed})
