-- Ink Game uncertainty-aware intent-ensemble auto dodge v7.3 (PC)
-- F1 toggles the system. It starts OFF.
-- Kick check is in this same file. users = buyers, whitelisted = extra, blacklisted = blocked.

if not game:IsLoaded() then
    game.Loaded:Wait()
end

if game.GameId ~= 7008097940 then
    warn("[Ink Auto Dodge] Wrong universe: " .. tostring(game.GameId))
    return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

do
    local LIST_URL = "https://raw.githubusercontent.com/Allen10111/ink/main/tables.txt"
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
    local function deny(reason)
        pcall(function()
            LocalPlayer:Kick(reason or "Not authorized")
        end)
    end
    local ok, users, blacklisted, whitelisted = pcall(function()
        return loadstring(game:HttpGet(LIST_URL))()
    end)
    if not ok then
        deny("Failed to load access list")
        return
    end
    local me = LocalPlayer.Name
    if nameInList(me, blacklisted) then
        deny("You are blacklisted")
        return
    end
    if not (nameInList(me, users) or nameInList(me, whitelisted)) then
        deny("You did not buy this script")
        return
    end
end

if not UserInputService.KeyboardEnabled then
    warn("[Ink Auto Dodge] PC keyboard version only")
    return
end

loadstring(game:HttpGet("https://raw.githubusercontent.com/Allen10111/ink/a630a126770844eae7a47e3d246377b4d1e7a121/ink_auto_dodge.lua"))()
