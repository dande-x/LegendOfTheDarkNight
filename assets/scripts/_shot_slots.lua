-- 截图入口：存档槽位界面（预置一个战士存档）
require "main"
local CharacterClass = require("CharacterClass")
local Inventory = require("Inventory")
local GameUI = require("GameUI")
local SaveSystem = require("SaveSystem")

function Start()
    graphics.windowTitle = "暗夜传奇-截图"
    GameUI.InitUI()
    GameUI.InitNanoVG()
    CreateScene()
    SetupCamera()
    SaveSystem.Init()
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")

    Inventory.Init()
    local player = CharacterClass.CreatePlayer("warrior", 8, "old", "male")
    local snapshot = SaveSystem.CreateSnapshot(player, Inventory.playerData, 12)
    if snapshot then
        SaveSystem.SaveToSlot(1, snapshot)
        GameUI.SetSelectedSlot(1)
    end
    ShowSaveSlotScreen()
    print("[shot_slots] save slot screen shown")
end
