-- Script: VerifyLevelWeaponSkinFlow | Type: isolated Studio Edit regression tool (V6.31)
-- Studio path: project MCP execute_luau; no Play, no real Remote traffic, no DataStore.
-- Covers: unlock catalog math, equip/reset/auto state rules, per-slot visual resolution,
-- special-skin mutex, persistence round-trip (explicit false kept), WeaponService visual
-- template wiring on real templates, LevelWeaponSkinService validation, lazy UI creation,
-- card reuse, closed-window buffering, duplicate state suppression and incremental refresh.
assert(game.PlaceId == 73988417166286)
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning())
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local HttpService = game:GetService("HttpService")
local passed, failed = {}, {}
local clockNow = 100
local function forbidden() error("External side effect attempted by isolated verification") end
local actors = {
    IsPlayer = function(a) return type(a) == "table" and a.UserId ~= nil end,
    IsBot = function() return false end,
    GetActorId = function(a) return a.UserId end,
    GetActorKind = function() return "Player" end,
    GetCombatUserId = function(a) return a.UserId end,
    GetRootPart = function() return nil end,
    GetHumanoid = function() return nil end,
    GetCharacter = function() return nil end,
}
local fakeGame = {}
local fakePlayersByUserId = {}
function fakeGame:GetService(name)
    if name == "Players" then
        return {GetPlayers=function() return {} end, GetPlayerByUserId=function(_,userId) return fakePlayersByUserId[userId] end}
    elseif name == "DataStoreService" or name == "MarketplaceService" then
        return setmetatable({}, {__index=function() return forbidden end})
    end
    return game:GetService(name)
end
local modules={}
local loadModule
loadModule=function(instance)
    if instance.Name == "ActorUtils" then return actors end
    if modules[instance] ~= nil then return modules[instance] end
    local source=sourceOverrides and sourceOverrides[instance.Name] or instance.Source
    local chunk,err=loadstring(source,"="..instance.Name)
    assert(chunk,err)
    setfenv(chunk,setmetatable({script=instance,game=fakeGame,require=loadModule,
        os=setmetatable({clock=function() return clockNow end},{__index=os}),
        task={delay=forbidden,spawn=forbidden,defer=forbidden,wait=forbidden},
    },{__index=getfenv()}))
    modules[instance]=chunk()
    return modules[instance]
end
local shared=game.ReplicatedStorage.Shared
local services=game.ServerScriptService.Services
local controllers=game.StarterPlayer.StarterPlayerScripts.Controllers
local WeaponTierConfig=loadModule(shared.WeaponTierConfig)
local SkinConfig=loadModule(shared.SkinConfig)
local PlayerState=loadModule(services.PlayerStateService)
local Weapon=loadModule(services.WeaponService)
local Rebirth=loadModule(services.RebirthService)
local LevelSkinService=loadModule(services.LevelWeaponSkinService)
local Controller=loadModule(controllers.LevelWeaponSkinController)
local ModalUi=loadModule(controllers.ModalUiController)
local formalWindowVisibleBefore=game.StarterGui.Main.LevelWeaponSkins.Visible
local function eq(a,b,label) assert(a==b,(label or "value")..": "..tostring(a).." ~= "..tostring(b)) end
local function test(name,callback)
    clockNow+=20
    local ok,err=pcall(callback)
    if ok then table.insert(passed,name) else table.insert(failed,{name=name,error=tostring(err)}) end
end
local function cloneService(module)
    local result=table.clone(module)
    for key,value in pairs(result) do if type(value)=="table" and key:sub(1,1)=="_" then result[key]={} end end
    return result
end
local function fixture(highestLevel)
    local p={UserId=91614,Name="LevelSkinVerification",Parent=true}
    local attributes={}
    p.SetAttribute=function(_,key,value) attributes[key]=value end
    p.GetAttribute=function(_,key) return attributes[key] end
    fakePlayersByUserId[p.UserId]=p
    local ps=cloneService(PlayerState)
    for _,name in ipairs({"_syncLeaderstats","SyncHumanoidMovement","SyncCharacterState","UpdateOverheadHealthBar","CheckTitleUnlocks","RefreshOnlineTime","PushState"}) do ps[name]=function() end end
    local state=ps:_createDefaultState(p)
    ps._statesByActorId[p.UserId]=state
    state.Alive=true; state.IsInArena=true
    if highestLevel then
        state.Level=highestLevel
        state.HighestLevelReached=highestLevel
    end
    return {p=p,ps=ps,state=state}
end

-- 1) Catalog thresholds
test("Catalog: 40 tiers, T1=1, T6=51, T7=61, T40=391",function()
    eq(WeaponTierConfig.TotalTierCount,40)
    eq(WeaponTierConfig.GetUnlockLevelForTierIndex(1),1)
    eq(WeaponTierConfig.GetUnlockLevelForTierIndex(6),51)
    eq(WeaponTierConfig.GetUnlockLevelForTierIndex(7),61)
    eq(WeaponTierConfig.GetUnlockLevelForTierIndex(40),391)
end)

-- 2) Defaults
test("Default state has no manual selection and auto upgrade on",function()
    local f=fixture()
    eq(f.state.SelectedLevelWeaponTierIndex,nil)
    eq(f.state.AutoUpgradeLevelWeaponSkin,true)
    local s=f.ps:GetLevelWeaponSkinState(f.p)
    eq(s.selectedTierIndex,nil);eq(s.autoUpgrade,true);eq(s.maxUnlockedTierIndex,1)
end)

-- 3) Equip validation
test("Equip accepts unlocked T6 at highest 55 and rejects locked/invalid indices",function()
    local f=fixture(55)
    eq(select(2,f.ps:EquipLevelWeaponSkin(f.p,6)),"Equipped")
    eq(f.state.SelectedLevelWeaponTierIndex,6)
    eq(select(2,f.ps:EquipLevelWeaponSkin(f.p,7)),"Locked")
    eq(select(2,f.ps:EquipLevelWeaponSkin(f.p,0)),"InvalidTierIndex")
    eq(select(2,f.ps:EquipLevelWeaponSkin(f.p,41)),"InvalidTierIndex")
    eq(select(2,f.ps:EquipLevelWeaponSkin(f.p,2.5)),"InvalidTierIndex")
    eq(f.state.SelectedLevelWeaponTierIndex,6)
end)

-- 4) Per-slot resolution
test("Resolution: auto keeps higher actual tiers, fixed pins manual pick everywhere",function()
    local f=fixture(55)
    local tierConfig=function(index) return WeaponTierConfig.Tiers[WeaponTierConfig.Order[index]] end
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,tierConfig(1)),nil,"no selection")
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    local low=f.ps:GetLevelWeaponVisualConfig(f.p,tierConfig(1))
    eq(low.TemplateName,"Weapon006")
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,tierConfig(6)).TemplateName,"Weapon006")
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,tierConfig(7)),nil,"auto keeps T7 actual slot")
    assert(f.ps:SetLevelWeaponAutoUpgrade(f.p,false))
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,tierConfig(7)).TemplateName,"Weapon006","fixed mode pins T7 slot")
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,nil),nil,"nil tier config safe")
end)

-- 5) Lv61 mixed loadout
test("Lv61 loadout resolves 9xT6 look + 1xT7 actual under auto",function()
    local f=fixture(61)
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    local loadout=WeaponTierConfig.ResolveLoadoutForLevel(61)
    local visualSix,visualSeven=0,0
    for _,slot in ipairs(loadout.Weapons) do
        local cfg=f.ps:GetLevelWeaponVisualConfig(f.p,WeaponTierConfig.Tiers[slot.Tier])
        if cfg and cfg.TemplateName=="Weapon006" then visualSix+=1
        elseif cfg==nil then visualSeven+=1 end
    end
    eq(visualSix,9);eq(visualSeven,1)
end)

-- 6) T3 early pick behaves
test("T3 pick shows T3 below T3 slots and actual tier above",function()
    local f=fixture(100)
    assert(f.ps:EquipLevelWeaponSkin(f.p,3))
    local tierConfig=function(index) return WeaponTierConfig.Tiers[WeaponTierConfig.Order[index]] end
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,tierConfig(2)).TemplateName,"Weapon003")
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,tierConfig(4)),nil)
end)

-- 7) Special skin mutex
test("Level look clears equipped special skin and equipping a skin clears the pick",function()
    local f=fixture(55)
    local skin=SkinConfig.GetAllSkins and SkinConfig.GetAllSkins()[1] or nil
    assert(skin,"no skin in config")
    assert(f.ps:GrantSkin(f.p,skin.Id))
    assert(f.ps:EquipSkin(f.p,skin.Id))
    eq(f.state.EquippedSkinId,skin.Id)
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    eq(f.state.EquippedSkinId,nil)
    eq(f.state.OwnedSkins[tostring(skin.Id)],true,"ownership kept")
    assert(f.ps:EquipSkin(f.p,skin.Id))
    eq(f.state.SelectedLevelWeaponTierIndex,nil,"skin equip clears level pick")
    eq(f.state.AutoUpgradeLevelWeaponSkin,true,"auto flag survives skin equip")
end)

-- 8) Use Level Look
test("UseLevelWeaponLook resets pick, auto and special skin",function()
    local f=fixture(55)
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    assert(f.ps:SetLevelWeaponAutoUpgrade(f.p,false))
    f.state.EquippedSkinId=10001
    assert(f.ps:UseLevelWeaponLook(f.p))
    eq(f.state.SelectedLevelWeaponTierIndex,nil)
    eq(f.state.AutoUpgradeLevelWeaponSkin,true)
    eq(f.state.EquippedSkinId,nil)
end)

-- 9) Auto toggle rules
test("Auto off without pick pins highest unlocked; non-boolean rejected",function()
    local f=fixture(55)
    eq(select(2,f.ps:SetLevelWeaponAutoUpgrade(f.p,"yes")),"InvalidArgument")
    assert(f.ps:SetLevelWeaponAutoUpgrade(f.p,false))
    eq(f.state.SelectedLevelWeaponTierIndex,6,"pinned to unlocked max")
    eq(f.state.AutoUpgradeLevelWeaponSkin,false)
    assert(f.ps:SetLevelWeaponAutoUpgrade(f.p,true))
    eq(f.state.SelectedLevelWeaponTierIndex,6,"explicit pick not lost by re-enable")
    local g=fixture(55)
    assert(g.ps:EquipLevelWeaponSkin(g.p,3))
    assert(g.ps:SetLevelWeaponAutoUpgrade(g.p,false))
    eq(g.state.SelectedLevelWeaponTierIndex,3,"existing pick kept")
end)

-- 10) Persistence round-trip
test("Save/load round-trip keeps pick and explicit false; locked pick dropped on load",function()
    local f=fixture(55)
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    assert(f.ps:SetLevelWeaponAutoUpgrade(f.p,false))
    local rb=cloneService(Rebirth)
    rb._processedPurchaseIdsByPlayerId={}
    rb._playerStateService=f.ps;rb._loadStateByUserId[f.p.UserId]="Loaded"
    rb._dataStore={}
    local saved=rb:_buildSavePayload(f.p,{includeCombatSnapshot=false})
    eq(saved.selectedLevelWeaponTierIndex,6)
    eq(saved.autoUpgradeLevelWeaponSkin,false)
    -- Same-player reload: saved highest merges, pick and explicit false both survive.
    local g=fixture()
    fakePlayersByUserId[g.p.UserId]=g.p
    local load=cloneService(Rebirth)
    load._processedPurchaseIdsByPlayerId={}
    load._playerStateService=g.ps
    load._dataStore={GetAsync=function() return saved end}
    load:_loadPlayer(g.p)
    eq(g.state.SelectedLevelWeaponTierIndex,6)
    eq(g.state.AutoUpgradeLevelWeaponSkin,false)
    -- Threshold shift scenario: saved highest 40 makes the T6 pick (unlock 51) invalid.
    local shifted=table.clone(saved)
    shifted.highestLevelReached=40
    local h=fixture()
    fakePlayersByUserId[h.p.UserId]=h.p
    local load2=cloneService(Rebirth)
    load2._processedPurchaseIdsByPlayerId={}
    load2._playerStateService=h.ps
    load2._dataStore={GetAsync=function() return shifted end}
    load2:_loadPlayer(h.p)
    eq(h.state.SelectedLevelWeaponTierIndex,nil,"pick above merged highest dropped")
    eq(h.state.AutoUpgradeLevelWeaponSkin,false,"explicit false survives even when pick dropped")
end)

-- 11) Payload fields
test("PlayerStateSync payload exposes the two new read-only fields",function()
    local f=fixture(55)
    assert(f.ps:EquipLevelWeaponSkin(f.p,4))
    local payload=f.ps:BuildStatePayload(f.p)
    eq(payload.selectedLevelWeaponTierIndex,4)
    eq(payload.levelWeaponSkinAutoUpgrade,true)
end)

-- 12-15) WeaponService visual template wiring on real templates
local runtimeFolder=Instance.new("Folder")
runtimeFolder.Name="__LevelSkinVerifyRuntime"
runtimeFolder.Parent=game.ServerStorage
local function weaponFixture(ps)
    local ws=cloneService(Weapon)
    ws._templateFolder=game.ReplicatedStorage:FindFirstChild("Model") and game.ReplicatedStorage.Model:FindFirstChild("Weapon") or nil
    assert(ws._templateFolder,"ReplicatedStorage.Model.Weapon missing")
    ws._runtimeFolder=runtimeFolder
    ws._weaponByPart={}
    ws._nextWeaponId=1
    ws._playerStateService=ps
    ws._getFinalWeaponDamage=function() return 10 end
    ws._getFinalOrbitSpeed=function() return 1 end
    ws._getFinalOrbitDistance=function() return 5 end
    ws._getFinalWeaponScale=function() return 1 end
    return ws
end
local function makeWeapon(ws,actor,tierIndex)
    local loadout=WeaponTierConfig.ResolveLoadoutForLevel(1)
    local desired
    if tierIndex>1 then
        desired={Tier=WeaponTierConfig.Order[tierIndex],TierIndex=tierIndex,Damage=99,CombatRank=tierIndex}
    else
        desired=loadout.Weapons[1]
    end
    local state=ws:_createWeaponState(actor,desired,1,10,{})
    assert(state,"_createWeaponState returned nil")
    return state
end
test("WeaponService defaults to actual tier template and keeps stats",function()
    local f=fixture(55)
    local ws=weaponFixture(f.ps)
    local w=makeWeapon(ws,f.p,1)
    eq(w.VisualTemplateName,"Weapon001")
    eq(w.VisualSkinId,nil)
    eq(w.Tier,"T1");eq(w.TierIndex,1)
    eq(w.RuntimeInstance.Name:sub(1,9),"Weapon001")
end)
test("Selected T6 look swaps only the visual template of a T1 slot",function()
    local f=fixture(55)
    local ws=weaponFixture(f.ps)
    local base=makeWeapon(ws,f.p,1)
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    local ws2=weaponFixture(f.ps)
    local look=makeWeapon(ws2,f.p,1)
    eq(look.VisualTemplateName,"Weapon006")
    eq(look.RuntimeInstance.Name:sub(1,9),"Weapon006")
    eq(look.Tier,"T1");eq(look.TierIndex,1)
    eq(look.VisualSkinId,nil)
    eq(look.VisualIconImage,WeaponTierConfig.Tiers[WeaponTierConfig.Order[6]].IconImage)
    eq(look.AuraRadius,base.AuraRadius,"hit radius unchanged by look")
end)
test("Auto off pins T7 slot to T6 template; equipped special skin still wins",function()
    local f=fixture(61)
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    assert(f.ps:SetLevelWeaponAutoUpgrade(f.p,false))
    local ws=weaponFixture(f.ps)
    local pinned=makeWeapon(ws,f.p,7)
    eq(pinned.VisualTemplateName,"Weapon006")
    eq(pinned.Tier,"T7")
    local g=fixture(61)
    local skin=SkinConfig.GetAllSkins and SkinConfig.GetAllSkins()[1] or nil
    assert(g.ps:GrantSkin(g.p,skin.Id))
    assert(g.ps:EquipSkin(g.p,skin.Id))
    -- level pick was cleared by EquipSkin; special skin drives the visual template
    local ws2=weaponFixture(g.ps)
    local skinned=makeWeapon(ws2,g.p,1)
    eq(skinned.VisualTemplateName,skin.TemplateName)
    eq(skinned.VisualSkinId,skin.Id)
end)
test("Resolution ignores bogus tier configs",function()
    local f=fixture(55)
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,{}),nil)
    eq(f.ps:GetLevelWeaponVisualConfig(f.p,nil),nil)
end)

-- V6.32: exercise the new wheel skin through real inventory, persistence and visuals.
test("Boneblade has independent normal/customize icons and Butter retains its identity",function()
    local skin=assert(SkinConfig.GetSkin(10010))
    eq(skin.Name,"Boneblade");eq(skin.TemplateName,"Skin010")
    eq(skin.IconImage,"rbxassetid://134985274966114")
    eq(skin.CustomizeIconImage,"rbxassetid://119304517377816")
    eq(SkinConfig.IsWheelSkin(skin),true)
    local butter=assert(SkinConfig.GetSkin(10009))
    eq(butter.Name,"Butter");eq(butter.TemplateName,"Skin009");eq(butter.IsRetired,true)
end)
test("Customize hides unowned Butter, preserves owned Butter and uses Boneblade display icon",function()
    local c=cloneService(loadModule(controllers.SkinController))
    c._latestState={skins={}}
    local byId={}
    for _,entry in ipairs(c:_getSkinEntries()) do byId[entry.id]=entry end
    eq(byId[10009],nil)
    eq(byId[10010].iconImage,"rbxassetid://119304517377816")
    eq(byId[10010].owned,false)
    c._latestState={skins={{id=10009,owned=true},{id=10010,owned=true,iconImage="rbxassetid://134985274966114"}},equippedSkinId=10009}
    for _,entry in ipairs(c:_getSkinEntries()) do byId[entry.id]=entry end
    eq(byId[10009].owned,true);eq(byId[10009].equipped,true)
    eq(byId[10010].iconImage,"rbxassetid://119304517377816","normal state icon cannot replace customize art")
end)
test("Boneblade needs ownership, renders Skin010 and keeps damage and hit radius",function()
    local f=fixture(55)
    eq(select(2,f.ps:EquipSkin(f.p,10010)),"NotOwned")
    local base=makeWeapon(weaponFixture(f.ps),f.p,1)
    assert(f.ps:GrantSkin(f.p,10010));assert(f.ps:EquipSkin(f.p,10010))
    local look=makeWeapon(weaponFixture(f.ps),f.p,1)
    eq(look.VisualTemplateName,"Skin010");eq(look.VisualSkinId,10010)
    assert(look.RuntimeInstance:FindFirstChild("SkeletonSword"),"new mesh not cloned")
    eq(look.VisualIconImage,"rbxassetid://134985274966114")
    eq(look.TierBaseDamage,base.TierBaseDamage);eq(look.BaseDamage,base.BaseDamage)
    eq(look.AuraRadius,base.AuraRadius);eq(look.CombatRank,base.CombatRank)
    assert(f.ps:ClearEquippedSkin(f.p))
    eq(makeWeapon(weaponFixture(f.ps),f.p,1).VisualTemplateName,"Weapon001")
end)
test("Butter-only owner wins Boneblade once, then receives the configured duplicate diamonds",function()
    local f=fixture(55)
    assert(f.ps:GrantSkin(f.p,10009))
    local svc=cloneService(loadModule(services.SkinService))
    svc._playerStateService=f.ps
    svc._rebirthService={IsPlayerLoaded=function() return true end,MarkDirty=function() end}
    local wheel=cloneService(loadModule(services.WheelService))
    wheel._playerStateService=f.ps;wheel._skinService=svc
    local config=loadModule(shared.WheelConfig)
    local reward=config.GetRewardBySlot(3)
    eq(reward.SkinId,10010);eq(reward.Label,"Boneblade");eq(config.TotalWeight,100)
    local diamonds=f.state.Diamonds
    local ok,_,award=wheel:_grantReward(f.p,reward)
    eq(ok,true);eq(award.awardedRewardType,"Skin");eq(award.pending,false)
    eq(f.ps:OwnsSkin(f.p,10010),true);eq(f.ps:OwnsSkin(f.p,10009),true)
    eq(f.state.Diamonds,diamonds,"old Butter is not a Boneblade duplicate")
    local ok2,reason,award2=wheel:_grantReward(f.p,reward)
    eq(ok2,true);eq(reason,"DuplicateConverted");eq(award2.awardedAmount,5000)
    eq(f.state.Diamonds,diamonds+5000)
end)
test("Boneblade and legacy Butter survive save/load with their own equipped identities",function()
    for _,equipped in ipairs({10010,10009}) do
        local f=fixture(55)
        assert(f.ps:GrantSkin(f.p,10009));assert(f.ps:GrantSkin(f.p,10010))
        assert(f.ps:EquipSkin(f.p,equipped))
        local rb=cloneService(Rebirth)
        rb._processedPurchaseIdsByPlayerId={};rb._playerStateService=f.ps
        rb._loadStateByUserId[f.p.UserId]="Loaded";rb._dataStore={}
        local saved=rb:_buildSavePayload(f.p,{includeCombatSnapshot=false})
        eq(saved.ownedSkins["10009"],true);eq(saved.ownedSkins["10010"],true)
        local g=fixture();local load=cloneService(Rebirth)
        load._processedPurchaseIdsByPlayerId={};load._playerStateService=g.ps
        load._dataStore={GetAsync=function() return saved end}
        load:_loadPlayer(g.p)
        eq(g.ps:OwnsSkin(g.p,10009),true);eq(g.ps:OwnsSkin(g.p,10010),true)
        eq(g.ps:GetEquippedSkinId(g.p),equipped)
    end
end)
test("Retired acquisition cannot point to wheel while Boneblade remains wheel-only",function()
    local f=fixture(55)
    local svc=cloneService(loadModule(services.SkinService))
    svc._playerStateService=f.ps
    svc._rebirthService={IsPlayerLoaded=function() return true end}
    local feedback={}
    svc._fireFeedback=function(_,_,kind,reason) table.insert(feedback,{kind,reason}) end
    svc:_handlePurchaseRequest(f.p,10009)
    eq(feedback[1][1],"Failed");eq(feedback[1][2],"Unavailable")
    svc:_handlePurchaseRequest(f.p,10010)
    eq(feedback[2][1],"OpenWheel");eq(feedback[2][2],"WheelOnly")
    eq(f.ps:OwnsSkin(f.p,10010),false,"opening wheel must not grant skin")
end)

-- 16-20) LevelWeaponSkinService validation
local function serviceFixture(highestLevel,loaded)
    local f=fixture(highestLevel)
    local captured={LevelWeaponSkinStateSync={},LevelWeaponSkinFeedback={}}
    local handlers={}
    local function fakeEvent(kind)
        return {
            OnServerEvent={Connect=function(_,cb) handlers[kind]=cb return {Disconnect=function() end} end},
            FireClient=function(_,player,payload) table.insert(captured[kind],payload) end,
        }
    end
    local remotes={}
    for _,kind in ipairs({"LevelWeaponSkinStateSync","RequestLevelWeaponSkinStateSync","RequestLevelWeaponSkinEquip","LevelWeaponSkinFeedback"}) do
        remotes[kind]=fakeEvent(kind)
    end
    local svc=cloneService(LevelSkinService)
    svc._remoteEventService={GetEvent=function(_,key) return remotes[key] end}
    svc._playerStateService=f.ps
    svc._rebirthService={IsPlayerLoaded=function() return loaded~=false end,MarkDirty=function() end}
    svc:Init({RemoteEventService=svc._remoteEventService,PlayerStateService=f.ps,RebirthService=svc._rebirthService})
    return {f=f,svc=svc,handlers=handlers,captured=captured}
end
test("State request pushes authoritative payload",function()
    local s=serviceFixture(55,true)
    s.handlers.RequestLevelWeaponSkinStateSync(s.f.p)
    local payload=s.captured.LevelWeaponSkinStateSync[1]
    eq(payload.selectedTierIndex,nil);eq(payload.autoUpgrade,true)
    eq(payload.highestLevelReached,55);eq(payload.totalTierCount,40)
    eq(payload.maxUnlockedTierIndex,6)
end)
test("Equip intent equips unlocked tier, pushes state and Equipped feedback",function()
    local s=serviceFixture(55,true)
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,6)
    eq(s.f.state.SelectedLevelWeaponTierIndex,6)
    local feedback=s.captured.LevelWeaponSkinFeedback[#s.captured.LevelWeaponSkinFeedback]
    eq(feedback.eventType,"Equipped")
    eq(feedback.state.selectedTierIndex,6)
end)
test("Locked / invalid / non-boolean requests fail without state change",function()
    local s=serviceFixture(55,true)
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,7)
    local feedback=s.captured.LevelWeaponSkinFeedback[#s.captured.LevelWeaponSkinFeedback]
    eq(feedback.eventType,"Failed");eq(feedback.reason,"Locked")
    clockNow+=1
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,41)
    eq(s.captured.LevelWeaponSkinFeedback[#s.captured.LevelWeaponSkinFeedback].reason,"InvalidArgument")
    clockNow+=1
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,"AutoUpgrade","yes")
    eq(s.captured.LevelWeaponSkinFeedback[#s.captured.LevelWeaponSkinFeedback].reason,"InvalidArgument")
    clockNow+=1
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,{})
    eq(s.captured.LevelWeaponSkinFeedback[#s.captured.LevelWeaponSkinFeedback].reason,"InvalidArgument")
    eq(s.f.state.SelectedLevelWeaponTierIndex,nil)
end)
test("AutoUpgrade boolean and UseLevelLook accepted; debounce and data-loading rejected",function()
    local s=serviceFixture(55,true)
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,"AutoUpgrade",false)
    eq(s.f.state.AutoUpgradeLevelWeaponSkin,false)
    eq(s.f.state.SelectedLevelWeaponTierIndex,6,"auto off without pick pins max unlocked")
    clockNow+=1
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,"UseLevelLook")
    eq(s.f.state.SelectedLevelWeaponTierIndex,nil)
    eq(s.f.state.AutoUpgradeLevelWeaponSkin,true)
    clockNow+=1
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,6)
    eq(s.f.state.SelectedLevelWeaponTierIndex,6)
    local loaded=serviceFixture(55,false)
    loaded.handlers.RequestLevelWeaponSkinEquip(loaded.f.p,6)
    local fb=loaded.captured.LevelWeaponSkinFeedback[#loaded.captured.LevelWeaponSkinFeedback]
    eq(fb.eventType,"Failed");eq(fb.reason,"DataLoading")
    eq(loaded.f.state.SelectedLevelWeaponTierIndex,nil)
end)
test("Rapid duplicate equip is debounced",function()
    local s=serviceFixture(55,true)
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,6)
    s.handlers.RequestLevelWeaponSkinEquip(s.f.p,5) -- same os.clock -> Debounced
    local fb=s.captured.LevelWeaponSkinFeedback[#s.captured.LevelWeaponSkinFeedback]
    eq(fb.eventType,"Failed");eq(fb.reason,"Debounced")
    eq(s.f.state.SelectedLevelWeaponTierIndex,6)
end)

-- Controller behavior on clones of the formal single-template window.
local guiFolder=Instance.new("Folder")
guiFolder.Name="__LevelSkinVerifyGui"
guiFolder.Parent=game.ServerStorage
local modalCalls={}
local savedOpen,savedClose=ModalUi.PlayPanelOpen,ModalUi.PlayPanelClose
ModalUi.PlayPanelOpen=function(_,owner,panel)
    table.insert(modalCalls,{op="open",owner=owner,panel=panel})
    if panel then panel.Visible=true end
end
ModalUi.PlayPanelClose=function(_,owner,panel)
    table.insert(modalCalls,{op="close",owner=owner,panel=panel})
    if panel then panel.Visible=false end
end
local function controllerCatalog()
    local catalog={}
    for index=1,WeaponTierConfig.TotalTierCount do
        local tier=WeaponTierConfig.Order[index]
        catalog[index]={tierIndex=index,name=WeaponTierConfig.GetDisplayNameForTier(tier),
            icon=WeaponTierConfig.GetIconImageForTier(tier),unlockLevel=WeaponTierConfig.GetUnlockLevelForTierIndex(index)}
    end
    return catalog
end
local function controllerFixture(windowClone)
    local c=cloneService(Controller)
    local attributes={}
    local attributeHandlers={}
    c._localPlayer={
        GetAttribute=function(_,name) return attributes[name] end,
        SetAttribute=function(_,name,value) attributes[name]=value
            local handlers=attributeHandlers[name]
            if handlers then for _,cb in ipairs(handlers) do cb() end end end,
        GetAttributeChangedSignal=function(_,name)
            attributeHandlers[name]=attributeHandlers[name] or {}
            return {Connect=function(_,cb) table.insert(attributeHandlers[name],cb) return {Disconnect=function() end} end}
        end,
    }
    c._catalog=controllerCatalog()
    c._requestStateEvent={FireServer=function() table.insert(modalCalls,{op="requestState"}) end}
    c._requestEquipEvent={FireServer=function(_,payload,extra) table.insert(modalCalls,{op="requestEquip",payload=payload,extra=extra}) end}
    c:_bindGmAttribute()
    c:_bindWindow(windowClone)
    return c
end
local function equipText(card)
    return card.EquipButton:FindFirstChild("Text")
end
local function cloneWindow()
    local window=game.StarterGui.Main.LevelWeaponSkins:Clone()
    window.Parent=guiFolder
    return window
end
-- Bind the actual controller through a narrow proxy for this one Activated signal.
-- All GUI properties and other methods still operate on the real template clone.
local function captureLevelLookActivation(window)
    local button=window.Content.UseLevelLookButton
    local listeners={}
    local activated={Connect=function(_,callback)
        local connection={Connected=true}
        function connection:Disconnect() self.Connected=false end
        table.insert(listeners,{callback=callback,connection=connection})
        return connection
    end}
    local function proxy(instance,overrides)
        return setmetatable({}, {
            __index=function(_,key)
                if overrides[key]~=nil then return overrides[key] end
                local value=instance[key]
                if type(value)=="function" then
                    return function(_,...) return value(instance,...) end
                end
                return value
            end,
            __newindex=function(_,key,value) instance[key]=value end,
        })
    end
    local buttonProxy=proxy(button,{Activated=activated})
    local content=window.Content
    local contentProxy=proxy(content,{FindFirstChild=function(_,name,...)
        if name=="UseLevelLookButton" then return buttonProxy end
        return content:FindFirstChild(name,...)
    end})
    local windowProxy=proxy(window,{FindFirstChild=function(_,name,...)
        if name=="Content" then return contentProxy end
        return window:FindFirstChild(name,...)
    end})
    local function activate()
        local connected=0
        for _,listener in ipairs(listeners) do
            if listener.connection.Connected then
                connected+=1
                listener.callback()
            end
        end
        eq(connected,1,"Use Level Look has one live Activated binding")
    end
    return windowProxy,activate
end
local function cardCount(scroll)
    local count=0
    for _,child in ipairs(scroll:GetChildren()) do
        if child.Name:match("^LevelWeapon_T%d+$") then count+=1 end
    end
    return count
end
local function optionalSummary(content,expected)
    local summary=content:FindFirstChild("SelectedSkinSummary")
    if summary then eq(summary.Text,expected) end
end
local function observeCardRenders(c)
    local calls={}
    local renderCard=c._renderCard
    c._renderCard=function(self,card,entry,...)
        table.insert(calls,entry.tierIndex)
        return renderCard(self,card,entry,...)
    end
    return calls
end
local function expectLevelLookButton(c,text,enabled,green)
    local button=c._content:FindFirstChild("UseLevelLookButton")
    eq(button:FindFirstChild("Text").Text,text)
    eq(button.Active,enabled,"reset Active")
    eq(button.Selectable,enabled,"reset Selectable")
    eq(button.Interactable,enabled,"reset Interactable")
    local background=button:FindFirstChild("ImageLabel")
    assert(background,"reset background exists")
    local greenGradient=background:FindFirstChild("ButtonGreen")
    local yellowGradient=background:FindFirstChild("ButtonYellow")
    assert(greenGradient and yellowGradient,"both reset color variants exist")
    eq(greenGradient.Enabled,green,"reset green state")
    eq(yellowGradient.Enabled,not green,"reset yellow state")
end
test("Binding creates zero cards; first open creates 40 cards with correct defaults",function()
    local window=cloneWindow()
    local c=controllerFixture(window)
    eq(window.Visible,false,"window stays hidden until opened")
    eq(cardCount(window.Content.ScrollingFrame),0,"bind must not precreate cards")
    eq(next(c._cardsByTierIndex),nil)
    local calls=observeCardRenders(c)
    c:_setOpen(true)
    eq(cardCount(window.Content.ScrollingFrame),40)
    eq(#calls,40,"first visible render initializes each card once")
    local dot=utf8.char(0x00B7)
    eq(window.Content.ProgressSummary.Text,"Best Lv. 1 "..dot.." 1/40 unlocked")
    optionalSummary(window.Content,"Chosen: Level Look")
    eq(window.Content.AutoUpgradeRow.CheckboxButton.Checkmark.Visible,true)
    eq(window.Content.ScrollingFrame.LevelWeapon_T1.EquipButton.Active,true)
    eq(equipText(window.Content.ScrollingFrame.LevelWeapon_T1).Text,"Equip")
    eq(equipText(window.Content.ScrollingFrame.LevelWeapon_T7).Text,"Locked")
    eq(window.Content.ScrollingFrame.LevelWeapon_T7.EquipButton.Active,false)
    eq(window.Content.ScrollingFrame.LevelWeapon_T1.EquippedBadge.Visible,false)
end)
test("State payload renders 6/40 unlocked, T6 selected, auto off",function()
    local window=cloneWindow()
    -- Static catalog data is set when cloning, not rewritten on every state event.
    local template=window.Content.ScrollingFrame.LevelWeaponTemplate
    template:FindFirstChild("Name").Text="StaleName"
    template.UnlockLevelText.Text="Unlock at Lv. 999"
    template.ItemTemplate.ItemIcon.Image="rbxassetid://1"
    local c=controllerFixture(window)
    c:_applyState({selectedTierIndex=6,autoUpgrade=false,highestLevelReached=55,maxUnlockedTierIndex=6})
    c:_setOpen(true)
    local dot=utf8.char(0x00B7)
    eq(window.Content.ProgressSummary.Text,"Best Lv. 55 "..dot.." 6/40 unlocked")
    optionalSummary(window.Content,"Chosen: "..WeaponTierConfig.GetDisplayNameForTier(WeaponTierConfig.Order[6]))
    eq(window.Content.AutoUpgradeRow.CheckboxButton.Checkmark.Visible,false)
    local t6=window.Content.ScrollingFrame.LevelWeapon_T6
    eq(t6.EquippedBadge.Visible,true);eq(t6.SelectionStroke.Enabled,true)
    eq(t6.EquipButton.Visible,false)
    local t2=window.Content.ScrollingFrame.LevelWeapon_T2
    eq(t2.EquipButton.Visible,true);eq(t2.EquipButton.Active,true);eq(equipText(t2).Text,"Equip")
    local t7=window.Content.ScrollingFrame.LevelWeapon_T7
    eq(equipText(t7).Text,"Locked");eq(t7.EquipButton.Active,false)
    eq(t7:GetAttribute("PreviewState"),"Locked");eq(t6:GetAttribute("PreviewState"),"Selected")
    eq(window.Content:GetAttribute("PreviewHighestLevel"),55)
    eq(window.Content:GetAttribute("PreviewSelectedTierIndex"),6)
    local t6card=window.Content.ScrollingFrame.LevelWeapon_T6
    eq(t6card:FindFirstChild("Name").Text,WeaponTierConfig.GetDisplayNameForTier(WeaponTierConfig.Order[6]))
    eq(t6card.UnlockLevelText.Text,"Unlock at Lv. 51")
    eq(t6card.ItemTemplate.ItemIcon.Image,WeaponTierConfig.GetIconImageForTier(WeaponTierConfig.Order[6]))
end)
test("Repeated open reuses all cards and event bindings without resetting scroll",function()
    local c=controllerFixture(cloneWindow())
    c:_setOpen(true)
    local cards=table.clone(c._cardsByTierIndex)
    local connections=table.clone(c._connectionsByWindow)
    local calls=observeCardRenders(c)
    c._scroll.AutomaticCanvasSize=Enum.AutomaticSize.None
    c._scroll.CanvasSize=UDim2.fromOffset(0,5000)
    c._scroll.CanvasPosition=Vector2.new(0,240)
    local savedPosition=c._scroll.CanvasPosition
    eq(savedPosition.Y,240,"fixture has a nonzero scroll position")
    for _=1,3 do c:_setOpen(false) c:_setOpen(true) end
    eq(#calls,0,"unchanged reopening must not redraw cards")
    eq(cardCount(c._scroll),40,"opening does not append copies")
    eq(c._scroll.CanvasPosition,savedPosition,"opening preserves scroll offset")
    eq(#c._connectionsByWindow,#connections,"opening adds no event bindings")
    for index,card in pairs(cards) do eq(c._cardsByTierIndex[index],card,"same card instance") end
    for index,connection in ipairs(connections) do
        eq(c._connectionsByWindow[index],connection,"same connection")
        eq(connection.Connected,true)
    end
end)
test("Closed before first open buffers only the latest state and creates no cards",function()
    local c=controllerFixture(cloneWindow())
    local calls=observeCardRenders(c)
    c:_applyState({selectedTierIndex=4,autoUpgrade=true,highestLevelReached=55,maxUnlockedTierIndex=6})
    c:_applyState({selectedTierIndex=6,autoUpgrade=false,highestLevelReached=61,maxUnlockedTierIndex=7})
    eq(cardCount(c._scroll),0)
    eq(#calls,0,"closed state sync must not render cards")
    eq(c._state.highestLevelReached,61)
    eq(c._state.selectedTierIndex,6)
    c:_setOpen(true)
    eq(#calls,40,"initialize once with latest state")
    eq(c._cardsByTierIndex[6].EquippedBadge.Visible,true)
    eq(c._cardsByTierIndex[7].EquipButton.Active,true)
    eq(c._cardsByTierIndex[4].EquippedBadge.Visible,false)
    eq(c._content.AutoUpgradeRow.CheckboxButton.Checkmark.Visible,false)
end)
test("Closed initialized window writes no cards; reopening applies only accumulated differences",function()
    local c=controllerFixture(cloneWindow())
    c:_applyState({selectedTierIndex=6,autoUpgrade=true,highestLevelReached=55,maxUnlockedTierIndex=6})
    c:_setOpen(true)
    local calls=observeCardRenders(c)
    local progressBefore=c._content.ProgressSummary.Text
    c:_setOpen(false)
    c:_applyState({selectedTierIndex=4,autoUpgrade=false,highestLevelReached=60,maxUnlockedTierIndex=6})
    c:_applyState({selectedTierIndex=5,autoUpgrade=false,highestLevelReached=61,maxUnlockedTierIndex=7})
    eq(#calls,0)
    eq(c._content.ProgressSummary.Text,progressBefore,"hidden labels stay untouched")
    eq(c._cardsByTierIndex[6].EquippedBadge.Visible,true,"hidden card keeps last rendered state")
    eq(c._cardsByTierIndex[7].EquipButton.Active,false)
    c:_setOpen(true)
    table.sort(calls)
    eq(#calls,3,"only old pick, latest pick and newly unlocked tier")
    eq(table.concat(calls,","),"5,6,7")
    eq(c._cardsByTierIndex[5].EquippedBadge.Visible,true)
    eq(c._cardsByTierIndex[6].EquippedBadge.Visible,false)
    eq(c._cardsByTierIndex[7].EquipButton.Active,true)
    eq(c._content.AutoUpgradeRow.CheckboxButton.Checkmark.Visible,false)
end)
test("Changing equipped tier renders exactly the old and new cards",function()
    local c=controllerFixture(cloneWindow())
    c:_applyState({selectedTierIndex=6,autoUpgrade=true,highestLevelReached=55,maxUnlockedTierIndex=6})
    c:_setOpen(true)
    local calls=observeCardRenders(c)
    c:_applyState({selectedTierIndex=5,autoUpgrade=true,highestLevelReached=55,maxUnlockedTierIndex=6})
    table.sort(calls)
    eq(table.concat(calls,","),"5,6")
    eq(c._cardsByTierIndex[5].SelectionHighlight.Visible,true)
    eq(c._cardsByTierIndex[6].SelectionHighlight.Visible,false)
end)
test("Level 55 to 60 refreshes no cards; 60 to 61 refreshes only newly unlocked T7",function()
    local c=controllerFixture(cloneWindow())
    c:_applyState({selectedTierIndex=6,autoUpgrade=true,highestLevelReached=55,maxUnlockedTierIndex=6})
    c:_setOpen(true)
    local calls=observeCardRenders(c)
    c:_applyState({selectedTierIndex=6,autoUpgrade=true,highestLevelReached=60,maxUnlockedTierIndex=6})
    eq(#calls,0,"same unlock band changes only summary")
    eq(c._content:GetAttribute("PreviewHighestLevel"),60)
    c:_applyState({selectedTierIndex=6,autoUpgrade=true,highestLevelReached=61,maxUnlockedTierIndex=7})
    eq(#calls,1)
    eq(calls[1],7)
    eq(c._cardsByTierIndex[7].EquipButton.Active,true)
    eq(c._cardsByTierIndex[8].EquipButton.Active,false)
end)
test("Auto mode change alone does not refresh cards",function()
    local c=controllerFixture(cloneWindow())
    c:_applyState({selectedTierIndex=6,autoUpgrade=true,highestLevelReached=55,maxUnlockedTierIndex=6})
    c:_setOpen(true)
    local calls=observeCardRenders(c)
    c:_applyState({selectedTierIndex=6,autoUpgrade=false,highestLevelReached=55,maxUnlockedTierIndex=6})
    eq(#calls,0)
    eq(c._content.AutoUpgradeRow.CheckboxButton.Checkmark.Visible,false)
end)
test("Modal-hidden open window buffers state until it becomes visible",function()
    local c=controllerFixture(cloneWindow())
    c:_setOpen(true)
    local calls=observeCardRenders(c)
    c._window.Visible=false
    c:_applyState({selectedTierIndex=1,autoUpgrade=true,highestLevelReached=1,maxUnlockedTierIndex=1})
    eq(#calls,0,"another modal hiding Armory suppresses card writes")
    c._window.Visible=true
    -- Explicit flush also works before a deferred Visible event runs.
    c:_render()
    eq(#calls,1)
    eq(calls[1],1)
    eq(c._cardsByTierIndex[1].EquippedBadge.Visible,true)
end)
test("Replacement window releases old connections and initializes from latest buffered state",function()
    local c=controllerFixture(cloneWindow())
    c:_applyState({selectedTierIndex=6,autoUpgrade=false,highestLevelReached=55,maxUnlockedTierIndex=6})
    c:_setOpen(true)
    local oldConnections=table.clone(c._connectionsByWindow)
    local oldCard=c._cardsByTierIndex[6]
    local replacement=cloneWindow()
    c:_bindWindow(replacement)
    for _,connection in ipairs(oldConnections) do eq(connection.Connected,false,"old window disconnected") end
    eq(cardCount(c._scroll),40,"open replacement honors pending open")
    assert(c._cardsByTierIndex[6]~=oldCard,"replacement uses its own cards")
    eq(c._cardsByTierIndex[6].EquippedBadge.Visible,true)
    c:_setOpen(false)
    local closedReplacement=cloneWindow()
    c:_bindWindow(closedReplacement)
    eq(cardCount(c._scroll),0,"closed replacement remains lazy")
    c:_applyState({selectedTierIndex=5,autoUpgrade=true,highestLevelReached=61,maxUnlockedTierIndex=7})
    eq(cardCount(c._scroll),0)
    c:_setOpen(true)
    eq(cardCount(c._scroll),40)
    eq(c._cardsByTierIndex[5].EquippedBadge.Visible,true)
    eq(c._cardsByTierIndex[7].EquipButton.Active,true)
end)
test("Use Level Look button distinguishes default, manual, special and fixed mode",function()
    local cases={
        {name="default",state={highestLevelReached=55,maxUnlockedTierIndex=6,autoUpgrade=true},isDefault=true},
        {name="manual",state={highestLevelReached=55,maxUnlockedTierIndex=6,autoUpgrade=true,selectedTierIndex=6}},
        {name="special",state={highestLevelReached=55,maxUnlockedTierIndex=6,autoUpgrade=true,equippedSkinId=10001}},
        {name="fixed without pick",state={highestLevelReached=55,maxUnlockedTierIndex=6,autoUpgrade=false}},
    }
    for _,case in ipairs(cases) do
        local window,activate=captureLevelLookActivation(cloneWindow())
        local c=controllerFixture(window)
        c:_applyState(case.state)
        c:_setOpen(true)
        local isDefault=case.isDefault==true
        expectLevelLookButton(c,isDefault and (utf8.char(0x2713).." Level Look") or "Use Level Look",not isDefault,isDefault)
        table.clear(modalCalls)
        activate()
        local sent=0
        for _,call in ipairs(modalCalls) do
            if call.op=="requestEquip" then
                sent+=1
                eq(call.payload,"UseLevelLook",case.name.." sends reset intent only")
                eq(call.extra,nil)
            end
        end
        eq(sent,isDefault and 0 or 1,case.name.." reset request count")
        eq(c._state.selectedTierIndex,case.state.selectedTierIndex,"UI intent does not mutate authoritative selection")
    end
end)
test("Use Level Look stays Loading and cannot send before state or Remote is ready",function()
    local window,activate=captureLevelLookActivation(cloneWindow())
    local c=controllerFixture(window)
    c:_setOpen(true)
    eq(c._state,nil)
    expectLevelLookButton(c,"Loading...",false,false)
    table.clear(modalCalls)
    activate()
    eq(#modalCalls,0,"unknown state must not send a reset")
    local remote=c._requestEquipEvent
    c._requestEquipEvent=nil
    c:_applyState({selectedTierIndex=6,autoUpgrade=true,highestLevelReached=55,maxUnlockedTierIndex=6})
    expectLevelLookButton(c,"Loading...",false,false)
    activate()
    eq(#modalCalls,0,"known state with missing remote cannot send")
    c._requestEquipEvent=remote
    -- No appearance value changes here; button readiness must update before dedupe.
    c:_render()
    expectLevelLookButton(c,"Use Level Look",true,false)
    activate()
    eq(#modalCalls,1)
    eq(modalCalls[1].payload,"UseLevelLook")
end)
test("GM attribute opens the window through ModalUi and requests state",function()
    local window=cloneWindow()
    local c=controllerFixture(window)
    c._localPlayer:SetAttribute("StudioLevelSkinUiPreview",true)
    local opened=false
    for _,call in ipairs(modalCalls) do
        if call.op=="open" and call.owner=="LevelWeaponSkins" and call.panel==window then opened=true end
    end
    assert(opened,"PlayPanelOpen not called for LevelWeaponSkins")
    c._localPlayer:SetAttribute("StudioLevelSkinUiPreview",false)
    local closed=false
    for _,call in ipairs(modalCalls) do
        if call.op=="close" and call.owner=="LevelWeaponSkins" then closed=true end
    end
    assert(closed,"PlayPanelClose not called")
end)
test("Request events fire equip intent only for unlocked tiers; close stays local",function()
    local window=cloneWindow()
    local c=controllerFixture(window)
    c:_applyState({selectedTierIndex=6,autoUpgrade=true,highestLevelReached=55,maxUnlockedTierIndex=6})
    table.clear(modalCalls)
    window.Content.AutoUpgradeRow.CheckboxButton:FindFirstChild("Checkmark")
    -- exercise intent helpers directly (Activated plumbing mirrors SkinController)
    c:_requestEquip("AutoUpgrade",false)
    c:_requestEquip("UseLevelLook")
    c:_requestEquip(6)
    local seen={}
    for _,call in ipairs(modalCalls) do
        if call.op=="requestEquip" then table.insert(seen,tostring(call.payload).."/"..tostring(call.extra)) end
    end
    eq(#seen,3)
    eq(seen[1],"AutoUpgrade/false");eq(seen[2],"UseLevelLook/nil");eq(seen[3],"6/nil")
    c:_setOpen(false)
    eq(c._isWindowOpen,false)
end)
test("Armory entry binds, opens the window and requests state (V6.27.1)",function()
    local window=cloneWindow()
    local c=controllerFixture(window)
    local armory=game.StarterGui.Main.Left:FindFirstChild("Armory")
    assert(armory,"Main.Left.Armory missing")
    local armoryClone=armory:Clone()
    armoryClone.Parent=guiFolder
    table.clear(modalCalls)
    eq(c:_bindArmory(armoryClone),true)
    eq(armoryClone.TextButton.Active,true)
    c:_onArmoryActivated()
    local opened=false
    for _,call in ipairs(modalCalls) do
        if call.op=="open" and call.owner=="LevelWeaponSkins" and call.panel==window then opened=true end
    end
    assert(opened,"Armory click did not open the window")
    local requested=false
    for _,call in ipairs(modalCalls) do
        if call.op=="requestState" then requested=true end
    end
    assert(requested,"Armory click did not request state")
    eq(c:_bindArmory(armoryClone),true,"rebinding same node stays idempotent")
end)
test("Late-arriving window honors a pending open request",function()
    table.clear(modalCalls)
    local c=cloneService(Controller)
    c._localPlayer={GetAttribute=function() return nil end}
    c._catalog=controllerCatalog()
    c._requestStateEvent={FireServer=function() table.insert(modalCalls,{op="requestState"}) end}
    c._requestEquipEvent={FireServer=function() end}
    c:_onArmoryActivated()
    eq(c._isWindowOpen,true)
    local openedEarly=false
    for _,call in ipairs(modalCalls) do
        if call.op=="open" then openedEarly=true end
    end
    eq(openedEarly,false,"no window yet, nothing to open")
    table.clear(modalCalls)
    local window=cloneWindow()
    c:_bindWindow(window)
    local openedLate=false
    for _,call in ipairs(modalCalls) do
        if call.op=="open" and call.owner=="LevelWeaponSkins" and call.panel==window then openedLate=true end
    end
    assert(openedLate,"pending open not replayed on late window bind")
    eq(cardCount(window.Content.ScrollingFrame),40,"late window initializes on pending open")
end)
test("PotionController luck entry prefers Main.BottomLeft.Luck (V6.27.1)",function()
    local Potion=loadModule(controllers.PotionController)
    local pc=cloneService(Potion)
    local entry=pc:_findLuckEntry(game.StarterGui.Main)
    assert(entry,"luck entry not found")
    eq(entry.Parent.Name,"BottomLeft")
    eq(entry.Name,"Luck")
    assert(game.StarterGui.Main.Left:FindFirstChild("Luck"),"legacy hidden node expected for fallback check")
end)

-- V6.27.2 regression: connect the actual controller/service through isolated events.
local function connectedController(s,captureResetButton)
    local RN=loadModule(shared.RemoteNames)
    local listeners,events={},{}
    for _,kind in ipairs({"PlayerStateSync","LevelWeaponSkinStateSync","LevelWeaponSkinFeedback","RequestLevelWeaponSkinStateSync","RequestLevelWeaponSkinEquip"}) do
        listeners[kind]={}
        events[RN.System[kind]]={
            OnClientEvent={Connect=function(_,cb) table.insert(listeners[kind],cb) return {Connected=true,Disconnect=function() end} end},
            FireServer=function(_,...) if s.handlers[kind] then s.handlers[kind](s.f.p,...) end end,
            FireClient=function(_,_,payload) for _,cb in ipairs(listeners[kind]) do cb(payload) end end,
        }
    end
    s.svc._stateSyncEvent=events[RN.System.LevelWeaponSkinStateSync]
    s.svc._feedbackEvent=events[RN.System.LevelWeaponSkinFeedback]
    s.f.ps._playerStateSyncEvent=events[RN.System.PlayerStateSync]
    s.f.ps.PushState=PlayerState.PushState
    local fakeRS={FindFirstChild=function(_,name) return game.ReplicatedStorage:FindFirstChild(name) end,
        WaitForChild=function(_,name) assert(name==RN.RootFolder) return {WaitForChild=function(_,inner)
            assert(inner==RN.SystemEventsFolder) return {WaitForChild=function(_,eventName) return events[eventName] end}
        end} end}
    local source=sourceOverrides and sourceOverrides.LevelWeaponSkinController or controllers.LevelWeaponSkinController.Source
    local chunk=assert(loadstring(source,"=ConnectedLevelSkinController"))
    setfenv(chunk,setmetatable({script=controllers.LevelWeaponSkinController,require=loadModule,
        game={GetService=function(_,name) if name=="ReplicatedStorage" then return fakeRS end return fakeGame:GetService(name) end},
        task={spawn=function(cb) cb() end,defer=forbidden,delay=forbidden,wait=forbidden},
    },{__index=getfenv()}))
    local c=cloneService(chunk())
    c._catalog=controllerCatalog()
    local window=cloneWindow()
    local activate
    if captureResetButton then window,activate=captureLevelLookActivation(window) end
    c:_bindWindow(window)
    c:_bindRemotes()
    return c,events,activate
end

test("Use Level Look Activated restores manual choice and repeating default is a no-op",function()
    local s=serviceFixture(55,true)
    assert(s.f.ps:EquipLevelWeaponSkin(s.f.p,6))
    local c,_,activate=connectedController(s,true)
    c:_setOpen(true)
    expectLevelLookButton(c,"Use Level Look",true,false)
    local cards=table.clone(c._cardsByTierIndex)
    local connections=table.clone(c._connectionsByWindow)
    local calls=observeCardRenders(c)
    local sent=0
    local remote=c._requestEquipEvent
    local fireServer=remote.FireServer
    remote.FireServer=function(self,payload,...)
        sent+=1
        eq(payload,"UseLevelLook")
        return fireServer(self,payload,...)
    end
    clockNow+=1
    activate()
    eq(sent,1)
    eq(s.f.state.SelectedLevelWeaponTierIndex,nil)
    eq(s.f.state.EquippedSkinId,nil)
    eq(s.f.state.AutoUpgradeLevelWeaponSkin,true)
    eq(c._state.selectedTierIndex,nil)
    eq(c._cardsByTierIndex[6].EquippedBadge.Visible,false)
    eq(c._cardsByTierIndex[6].SelectionHighlight.Visible,false)
    expectLevelLookButton(c,utf8.char(0x2713).." Level Look",false,true)
    eq(#calls,1,"reset refreshes only previously selected card")
    eq(calls[1],6)
    table.clear(calls)
    for _=1,3 do activate() end
    eq(sent,1,"default-state reset never reaches the Remote")
    eq(#calls,0,"default-state reset never refreshes cards")
    eq(cardCount(c._scroll),40,"reset keeps cached cards")
    for index,card in pairs(cards) do eq(c._cardsByTierIndex[index],card) end
    eq(#c._connectionsByWindow,#connections)
    for index,connection in ipairs(connections) do eq(c._connectionsByWindow[index],connection) end
end)
test("Use Level Look Activated clears a special skin without rewriting unrelated cards",function()
    local s=serviceFixture(55,true)
    local skin=SkinConfig.GetAllSkins()[1]
    assert(s.f.ps:GrantSkin(s.f.p,skin.Id))
    assert(s.f.ps:EquipSkin(s.f.p,skin.Id))
    local c,_,activate=connectedController(s,true)
    c:_setOpen(true)
    expectLevelLookButton(c,"Use Level Look",true,false)
    local calls=observeCardRenders(c)
    clockNow+=1
    activate()
    eq(s.f.state.EquippedSkinId,nil)
    eq(s.f.state.SelectedLevelWeaponTierIndex,nil)
    eq(s.f.state.AutoUpgradeLevelWeaponSkin,true)
    eq(c._state.equippedSkinId,nil)
    expectLevelLookButton(c,utf8.char(0x2713).." Level Look",false,true)
    eq(#calls,0,"special-to-level source change has no selected card to repaint")
end)
test("Use Level Look Activated restores auto upgrade and clears fixed-mode selection",function()
    local s=serviceFixture(55,true)
    assert(s.f.ps:SetLevelWeaponAutoUpgrade(s.f.p,false))
    eq(s.f.state.SelectedLevelWeaponTierIndex,6)
    local c,_,activate=connectedController(s,true)
    c:_setOpen(true)
    expectLevelLookButton(c,"Use Level Look",true,false)
    local calls=observeCardRenders(c)
    clockNow+=1
    activate()
    eq(s.f.state.AutoUpgradeLevelWeaponSkin,true)
    eq(s.f.state.SelectedLevelWeaponTierIndex,nil)
    eq(c._state.autoUpgrade,true)
    eq(c._content.AutoUpgradeRow.CheckboxButton.Checkmark.Visible,true)
    expectLevelLookButton(c,utf8.char(0x2713).." Level Look",false,true)
    eq(#calls,1)
    eq(calls[1],6)
end)

test("Open Armory reflects a new unlock from normal level-up",function()
    local s=serviceFixture(55,true)
    local c=connectedController(s)
    eq(c._state.highestLevelReached,55,"initial sync")
    c:_setOpen(true)
    local GameConfig=loadModule(shared.GameConfig)
    local xp=0
    for level=55,60 do xp+=GameConfig.GetNextLevelExperience(level) end
    assert(s.f.ps:AddExperience(s.f.p,xp))
    eq(s.f.state.HighestLevelReached,61,"authoritative highest")
    eq(c._state.highestLevelReached,61,"client highest after PlayerStateSync")
    eq(c._cardsByTierIndex[7].EquipButton.Active,true,"T7 selectable without reopening")
end)

test("Armory clears selected badge when original Skin equips",function()
    local s=serviceFixture(55,true)
    local c=connectedController(s)
    c:_setOpen(true)
    clockNow+=1
    c:_requestEquip(6)
    eq(c._state.selectedTierIndex,6,"level equip synced")
    local calls=observeCardRenders(c)
    local skin=SkinConfig.GetAllSkins()[1]
    assert(s.f.ps:GrantSkin(s.f.p,skin.Id))
    assert(s.f.ps:EquipSkin(s.f.p,skin.Id))
    eq(s.f.state.SelectedLevelWeaponTierIndex,nil,"server mutex clears manual pick")
    eq(c._state.selectedTierIndex,nil,"client selected badge clears")
    eq(c._cardsByTierIndex[6].EquippedBadge.Visible,false)
    eq(c._cardsByTierIndex[6].SelectionHighlight.Visible,false)
    eq(c._cardsByTierIndex[6].EquipButton.Active,true)
    eq(#calls,1,"special skin clears only former selected card")
    eq(calls[1],6)
    optionalSummary(c._content,"Chosen: Special Skin")
end)

test("Duplicate dedicated state, feedback and PlayerStateSync trigger zero redraws",function()
    local s=serviceFixture(55,true)
    local c,events=connectedController(s)
    c:_setOpen(true)
    clockNow+=1
    c:_requestEquip(6)
    local calls=observeCardRenders(c)
    local renderCount=0
    local render=c._render
    c._render=function(self) renderCount+=1 return render(self) end
    local RN=loadModule(shared.RemoteNames)
    clockNow+=1
    local state=s.f.ps:GetLevelWeaponSkinState(s.f.p)
    state.timestamp=clockNow
    events[RN.System.LevelWeaponSkinStateSync]:FireClient(s.f.p,state)
    events[RN.System.LevelWeaponSkinFeedback]:FireClient(s.f.p,{eventType="Equipped",state=state})
    s.f.ps:PushState(s.f.p)
    eq(#calls,0)
    eq(renderCount,0,"all state sources use the same appearance comparison")
    eq(c._lastStateTimestamp,clockNow,"fresh duplicate still advances stale-event guard")
    c:_applyState({selectedTierIndex=1,autoUpgrade=false,highestLevelReached=1,maxUnlockedTierIndex=1,timestamp=clockNow-1})
    eq(c._state.selectedTierIndex,6,"stale event cannot undo selection after duplicate")
    eq(renderCount,0)
end)

test("Auto off keeps special skin; explicit level equip changes source",function()
    local s=serviceFixture(55,true)
    local skin=SkinConfig.GetAllSkins()[1]
    assert(s.f.ps:GrantSkin(s.f.p,skin.Id))
    assert(s.f.ps:EquipSkin(s.f.p,skin.Id))
    local c=connectedController(s)
    c:_setOpen(true)
    eq(c._state.equippedSkinId,skin.Id,"dedicated state includes special skin")
    clockNow+=1
    c:_requestEquip("AutoUpgrade",false)
    eq(s.f.state.AutoUpgradeLevelWeaponSkin,false)
    eq(s.f.state.SelectedLevelWeaponTierIndex,nil,"auto toggle cannot equip a hidden level pick")
    eq(s.f.state.EquippedSkinId,skin.Id)
    eq(c._state.autoUpgrade,false)
    eq(c._state.selectedTierIndex,nil)
    eq(c._cardsByTierIndex[6].EquipButton.Visible,true)
    local ws=weaponFixture(s.f.ps)
    eq(makeWeapon(ws,s.f.p,1).VisualSkinId,skin.Id,"visual stays on special skin")
    clockNow+=1
    c:_requestEquip(6)
    eq(s.f.state.EquippedSkinId,nil)
    eq(s.f.state.SelectedLevelWeaponTierIndex,6)
    eq(c._state.equippedSkinId,nil)
    eq(c._state.autoUpgrade,false,"stored preference survives explicit equip")
    eq(makeWeapon(ws,s.f.p,1).VisualTemplateName,"Weapon006")
end)

test("Unequipping special skin honors stored fixed-mode preference",function()
    local s=serviceFixture(55,true)
    local skin=SkinConfig.GetAllSkins()[1]
    assert(s.f.ps:GrantSkin(s.f.p,skin.Id))
    assert(s.f.ps:EquipSkin(s.f.p,skin.Id))
    assert(s.f.ps:SetLevelWeaponAutoUpgrade(s.f.p,false))
    local c=connectedController(s)
    c:_setOpen(true)
    assert(s.f.ps:ClearEquippedSkin(s.f.p))
    eq(c._state.selectedTierIndex,6)
    eq(c._state.equippedSkinId,nil)
    eq(c._state.autoUpgrade,false)
    eq(c._cardsByTierIndex[6].EquippedBadge.Visible,true)
    local tier7=WeaponTierConfig.Tiers[WeaponTierConfig.Order[7]]
    eq(s.f.ps:GetLevelWeaponVisualConfig(s.f.p,tier7).TemplateName,"Weapon006")
    assert(s.f.ps:EquipSkin(s.f.p,skin.Id))
    assert(s.f.ps:SetLevelWeaponAutoUpgrade(s.f.p,true))
    assert(s.f.ps:ClearEquippedSkin(s.f.p))
    eq(c._state.selectedTierIndex,nil,"auto mode returns to level look")
    optionalSummary(c._content,"Chosen: Level Look")
end)

test("Late data load still updates Armory after initial 15-second push expires",function()
    local s=serviceFixture(nil,false)
    local c=connectedController(s)
    c:_setOpen(true)
    eq(c._state.highestLevelReached,1)
    -- Fast-forward only the isolated service's wait; never sleep or touch live players.
    local taskEnv=getfenv(LevelSkinService.OnPlayerAdded).task
    local oldSpawn,oldWait=taskEnv.spawn,taskEnv.wait
    taskEnv.spawn=function(cb) cb() end
    taskEnv.wait=function(seconds) clockNow+=seconds end
    local ok,err=pcall(function() s.svc:OnPlayerAdded(s.f.p) end)
    taskEnv.spawn,taskEnv.wait=oldSpawn,oldWait
    assert(ok,err)
    eq(c._state.highestLevelReached,1,"no loaded push was available")
    clockNow+=1
    local rb=cloneService(Rebirth)
    rb._playerStateService=s.f.ps
    rb._dataStore={GetAsync=function() return {highestLevelReached=55,selectedLevelWeaponTierIndex=6,autoUpgradeLevelWeaponSkin=false} end}
    rb:_loadPlayer(s.f.p)
    eq(c._state.highestLevelReached,55)
    eq(c._state.selectedTierIndex,6)
    eq(c._state.autoUpgrade,false,"explicit false from late load preserved")
    eq(c._cardsByTierIndex[6].EquippedBadge.Visible,true)
end)

test("Old dual-source save keeps special skin and repairs selected level pick",function()
    local f=fixture()
    local skin=SkinConfig.GetAllSkins()[1]
    local rb=cloneService(Rebirth)
    rb._processedPurchaseIdsByPlayerId={}
    rb._playerStateService=f.ps
    rb._dataStore={GetAsync=function() return {
        highestLevelReached=55,ownedSkins={[tostring(skin.Id)]=true},equippedSkinId=skin.Id,
        selectedLevelWeaponTierIndex=6,autoUpgradeLevelWeaponSkin=false,
    } end}
    rb:_loadPlayer(f.p)
    eq(f.state.EquippedSkinId,skin.Id)
    eq(f.state.SelectedLevelWeaponTierIndex,nil)
    eq(f.state.AutoUpgradeLevelWeaponSkin,false)
    local saved=rb:_buildSavePayload(f.p,{includeCombatSnapshot=false})
    eq(saved.equippedSkinId,skin.Id)
    eq(saved.selectedLevelWeaponTierIndex,nil,"next save contains one appearance source")
    eq(saved.autoUpgradeLevelWeaponSkin,false)
end)

test("Death reset and new character retain fixed T6 look at actual level 1",function()
    local f=fixture(55)
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    assert(f.ps:SetLevelWeaponAutoUpgrade(f.p,false))
    f.ps:ResetCombatState(f.p)
    f.ps:OnCharacterAdded(f.p)
    eq(f.state.Level,1)
    eq(f.state.HighestLevelReached,55)
    eq(f.state.SelectedLevelWeaponTierIndex,6)
    eq(f.state.AutoUpgradeLevelWeaponSkin,false)
    f.state.IsInArena=true
    local ws=weaponFixture(f.ps)
    ws:RebuildWeaponsForPlayer(f.p)
    local weapons=ws._weaponsByCombatUserId[f.p.UserId]
    eq(#weapons,1,"actual level 1 grants one weapon")
    eq(weapons[1].Tier,"T1")
    eq(weapons[1].VisualTemplateName,"Weapon006")
end)

test("Changing level appearance preserves missing weapons, recovery timer and real stats",function()
    local f=fixture(55)
    local ws=weaponFixture(f.ps)
    f.ps._weaponService=ws
    ws:_rebuildWeaponsForActorToCount(f.p,7)
    local before={}
    for i,w in ipairs(ws._weaponsByCombatUserId[f.p.UserId]) do
        before[i]={tier=w.Tier,damage=w.BaseDamage,rank=w.CombatRank,radius=w.AuraRadius}
    end
    local restoreAt=ws._weaponRestorationByCombatUserId[f.p.UserId].NextRestoreAt
    assert(f.ps:EquipLevelWeaponSkin(f.p,6))
    assert(f.ps:SetLevelWeaponAutoUpgrade(f.p,false))
    local weapons=ws._weaponsByCombatUserId[f.p.UserId]
    eq(#weapons,7,"appearance cannot restore three missing weapons")
    eq(ws._weaponRestorationByCombatUserId[f.p.UserId].NextRestoreAt,restoreAt)
    for i,w in ipairs(weapons) do
        eq(w.Tier,before[i].tier);eq(w.BaseDamage,before[i].damage)
        eq(w.CombatRank,before[i].rank);eq(w.AuraRadius,before[i].radius)
        eq(w.VisualTemplateName,"Weapon006")
    end
end)

test("Unrelated PlayerStateSync skips redraw and older dedicated states cannot roll back",function()
    local s=serviceFixture(55,true)
    local c=connectedController(s)
    c:_setOpen(true)
    local render=c._render
    local count=0
    c._render=function(self) count+=1 return render(self) end
    clockNow+=1
    s.f.ps:PushState(s.f.p)
    eq(count,0,"same appearance snapshot does not redraw 40 cards")
    local timestamp=clockNow
    c:_applyState({highestLevelReached=1,autoUpgrade=true,timestamp=timestamp-1})
    eq(c._state.highestLevelReached,55,"older dedicated state ignored")
    eq(count,0)
    clockNow+=1
    assert(s.f.ps:SetLevelWeaponAutoUpgrade(s.f.p,false))
    eq(count,1,"changed appearance triggers one general-state redraw")
    eq(c._state.autoUpgrade,false)
    eq(c._state.selectedTierIndex,6)
    clockNow+=1
    s.f.ps:PushState(s.f.p)
    eq(count,1)
    c:_applyPlayerState({highestLevelReached=1,timestamp=clockNow+1})
    eq(c._state.selectedTierIndex,6,"partial legacy state cannot clear a selection")
end)

ModalUi.PlayPanelOpen,ModalUi.PlayPanelClose=savedOpen,savedClose
for _,node in ipairs(guiFolder:GetChildren()) do node:Destroy() end
guiFolder:Destroy()
test("Formal UI retains editor visibility and only one hidden card template",function()
    eq(game.StarterGui.Main.Left.LevelWeaponSkinsButton.Visible,false)
    eq(game.StarterGui.Main.LevelWeaponSkins.Visible,formalWindowVisibleBefore,"verification preserves user's editor visibility")
    local scroll=game.StarterGui.Main.LevelWeaponSkins.Content.ScrollingFrame
    eq(cardCount(scroll),0,"formal UI must not ship 40 eager cards")
    eq(scroll.LevelWeaponTemplate.Visible,false)
    eq(game.StarterGui.Main.Left.Armory.Visible,true,"Armory HUD entry must stay visible")
    assert(game.StarterGui.Main:FindFirstChild("Skin"),"old Skin window missing")
    assert(game.StarterGui.Main.Skin:FindFirstChild("Tabs"),"old Skin tabs missing")
end)
runtimeFolder:Destroy()

return HttpService:JSONEncode({passed=#passed,failed=#failed,tests=passed,failures=failed})
