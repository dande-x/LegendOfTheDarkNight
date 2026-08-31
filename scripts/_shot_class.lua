-- 临时截图入口：职业选择界面（截完即删，不打包）
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

    GameUI.ShowClassSelect(function(classId, modelStyle, gender)
        print("[shot_class] selected " .. tostring(classId))
    end)
    print("[shot_class] class select shown")
end
