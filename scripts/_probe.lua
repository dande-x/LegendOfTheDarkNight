-- 探针：validate 模式下 scripts.X 是否可解析
function Start()
    local ok, err = pcall(require, "scripts.Balance")
    print("[probe] scripts.Balance => " .. (ok and "OK" or ("FAIL: " .. tostring(err))))
    engine:Exit()
end
