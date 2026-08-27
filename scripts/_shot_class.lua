-- 临时截图入口：职业选择界面（截完即删，不打包）
require "scripts.main"
local GameUI = require("scripts.GameUI")
local SaveSystem = require("scripts.SaveSystem")

function Start()
    graphics.windowTitle = "暗夜传奇-截图"
    GameUI.InitUI()
    GameUI.InitNanoVG()
    CreateScene()
    SetupCamera()
    SaveSystem.Init()
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")

    GameUI.ShowClassSelect(function(classId, modelStyle, gender)
        print("[shot_class] selected " .. tostring(classId))
    end)
    print("[shot_class] class select shown")
end
