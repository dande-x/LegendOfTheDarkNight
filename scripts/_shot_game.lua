-- 临时截图入口：直接载入角色进入游戏内战斗画面（截完即删，不打包）
require "main"
-- 与 canonical main 共享 UI/存档模块，避免截图入口重新加载旧镜像。
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

    local saveData = {
        classId = "warrior", level = 8, exp = 320,
        hp = 260, mp = 40, gold = 5200,
        mapId = "map_bq", gender = "male", modelStyle = "old",
        killCount = 12,
    }
    LoadFromSave(saveData)
    print("[shot_game] entered game for screenshot")
end
