--[[
脚本名字: ActorUtils
脚本文件: ActorUtils.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/ActorUtils
]]

local ActorUtils = {}

function ActorUtils.IsPlayer(actor)
    return typeof(actor) == "Instance" and actor:IsA("Player")
end

function ActorUtils.IsBot(actor)
    return type(actor) == "table" and actor.IsBot == true
end

function ActorUtils.GetActorKind(actor)
    if ActorUtils.IsPlayer(actor) then
        return "Player"
    end
    if ActorUtils.IsBot(actor) then
        return "Bot"
    end
    return "Unknown"
end

function ActorUtils.GetActorId(actor)
    if ActorUtils.IsPlayer(actor) then
        return string.format("player:%d", actor.UserId)
    end
    if ActorUtils.IsBot(actor) then
        return tostring(actor.ActorId or "")
    end
    return ""
end

function ActorUtils.GetCombatUserId(actor)
    if ActorUtils.IsPlayer(actor) then
        return actor.UserId
    end
    if ActorUtils.IsBot(actor) then
        return actor.UserId
    end
    return nil
end

function ActorUtils.GetActorName(actor)
    if ActorUtils.IsPlayer(actor) then
        return actor.Name
    end
    if ActorUtils.IsBot(actor) then
        return tostring(actor.Name or actor.ActorId or "Bot")
    end
    return "Unknown"
end

function ActorUtils.GetCharacter(actor)
    if ActorUtils.IsPlayer(actor) then
        return actor.Character
    end
    if ActorUtils.IsBot(actor) then
        return actor.Character
    end
    return nil
end

function ActorUtils.GetHumanoid(actor)
    local character = ActorUtils.GetCharacter(actor)
    if not character then
        return nil
    end
    return character:FindFirstChildOfClass("Humanoid")
end

function ActorUtils.GetRootPart(actor)
    local character = ActorUtils.GetCharacter(actor)
    if not character then
        return nil
    end
    return character:FindFirstChild("HumanoidRootPart")
end

function ActorUtils.IsSameActor(actorA, actorB)
    local actorIdA = ActorUtils.GetActorId(actorA)
    local actorIdB = ActorUtils.GetActorId(actorB)
    return actorIdA ~= "" and actorIdA == actorIdB
end

function ActorUtils.IsActorAlive(actor, state)
    local resolvedState = state
    if not resolvedState and ActorUtils.IsBot(actor) then
        resolvedState = actor.State
    end
    return resolvedState and resolvedState.Alive == true
end

return ActorUtils
