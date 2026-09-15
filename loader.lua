-- Run this file. It only allows names in tables.txt (users or whitelisted).
-- Blacklisted names are always blocked.

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local LIST_URL = "https://raw.githubusercontent.com/Allen10111/ink/main/tables.txt"
local SCRIPT_URL = "https://raw.githubusercontent.com/Allen10111/ink/main/ink_auto_dodge_mobile.lua"

local function nameInList(name, list)
    if type(list) ~= "table" then
        return false
    end
    name = string.lower(tostring(name))
    for _, entry in ipairs(list) do
        if string.lower(tostring(entry)) == name then
            return true
        end
    end
    return false
end

local ok, users, blacklisted, whitelisted = pcall(function()
    return loadstring(game:HttpGet(LIST_URL))()
end)

if not ok then
    warn("[Ink Auto Dodge] Failed to load access list")
    return
end

local me = LocalPlayer.Name

if nameInList(me, blacklisted) then
    warn("[Ink Auto Dodge] Access denied")
    return
end

if not (nameInList(me, users) or nameInList(me, whitelisted)) then
    warn("[Ink Auto Dodge] Access denied")
    return
end

print("[Ink Auto Dodge] Allowed:", me)
loadstring(game:HttpGet(SCRIPT_URL))()
