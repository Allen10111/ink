-- Ink Game auto dodge
-- Access:
--   users       = people who bought the script (allowed)
--   whitelisted = extra allowed names
--   blacklisted = blocked even if they bought it

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local LIST_URL = "https://raw.githubusercontent.com/Allen10111/ink/main/tables.txt"
local SCRIPT_URL = "https://raw.githubusercontent.com/Allen10111/ink/a630a126770844eae7a47e3d246377b4d1e7a121/ink_auto_dodge.lua"

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
local bought = nameInList(me, users)
local extra = nameInList(me, whitelisted)
local banned = nameInList(me, blacklisted)

if banned then
    deny("You are blacklisted")
    return
end

if not (bought or extra) then
    deny("You did not buy this script")
    return
end

loadstring(game:HttpGet(SCRIPT_URL))()
