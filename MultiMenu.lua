script_name("MultiMenu")
script_author("369Miko")
script_version("1.87")
script_description("Мульти-менюшка с нужными фишечками для гейзоновцев.")

require "lib.moonloader"
local vkeys = require "vkeys"
local sampev = require 'lib.samp.events'
local imgui = require 'mimgui'
local encoding = require 'encoding'
local inicfg = require 'inicfg'
local ffi = require 'ffi'
local requests = require('requests')
local json = require('json')

local JSON_URL = "https://raw.githubusercontent.com/369miko/MultiMenu/main/MultiMenu.json"
local SCRIPT_FILENAME = "MultiMenu.lua"

local isAutomatingSport = false
local isAutomatingDrift = false
local scriptKeyAction = false
local lastServerId = 0
local lastVehicle = -1

local old_addEventHandler = addEventHandler
addEventHandler = function(name, cb)
    if name == "onReceivePacket" then
        local safe_cb = function(id, bs)
            if id == 220 and not (isAutomatingSport or isAutomatingDrift) then
                return 
            end
            local ok, res = pcall(cb, id, bs)
            if ok then return res end
        end
        old_addEventHandler(name, safe_cb)
    elseif name == "onSendPacket" then
        local safe_cb = function(id, bs)
            local ok, res = pcall(cb, id, bs)
            if ok then return res end
        end
        old_addEventHandler(name, safe_cb)
    else
        old_addEventHandler(name, cb)
    end
end

local ae = require 'arizona-events'
addEventHandler = old_addEventHandler

ffi.cdef[[
    void* LoadLibraryA(const char* lpLibFileName);
    void* GetProcAddress(void* hModule, const char* lpProcName);
    int   FreeLibrary(void* hModule);
]]
local kernel32 = ffi.load('kernel32')

local MARKET_DIALOG_ID = 15073

local default_cfg = {
    toggles = { 
        balloon = true, 
        bodycam = true, 
        unfreeze = true, 
        fisheye = true, 
        hand = true, 
        limit = true, 
        anim68 = true, 
        autosport = false, 
        autodrift = false,
        antibpwb = false,
        oldesc = false,
        dlgstyle_enabled = false,
        autotax = false
    },
    keys = { 
        balloon = 0x2E,
        unfreeze = 0x7B,
        hand = 0x06,
        limit = 0x43,
        anim68 = 0x51
    },
    mods = {
        balloon = 0,
        unfreeze = 0,
        hand = 0,
        limit = 0,
        anim68 = 0x12
    },
    settings = {
        fisheye_fov = 90.0,
        best_captcha_time = 0.0,
        dialog_style = 1,
        autotax_interval = 10
    }
}

local mainIni = inicfg.load(default_cfg, "fishki.ini")
if not mainIni.mods then mainIni.mods = {} end
if not mainIni.settings then mainIni.settings = {} end
if mainIni.settings.fisheye_fov == nil then mainIni.settings.fisheye_fov = 90.0 end
if mainIni.settings.best_captcha_time == nil then mainIni.settings.best_captcha_time = 0.0 end
if mainIni.settings.dialog_style == nil or mainIni.settings.dialog_style < 1 then mainIni.settings.dialog_style = 1 end
if mainIni.settings.autotax_interval == nil then mainIni.settings.autotax_interval = 10 end
for k, v in pairs(default_cfg.keys) do
    if mainIni.keys[k] == nil then mainIni.keys[k] = v end
    if mainIni.mods[k] == nil then mainIni.mods[k] = default_cfg.mods[k] end
end
for k, v in pairs(default_cfg.toggles) do
    if mainIni.toggles[k] == nil then mainIni.toggles[k] = v end
end
inicfg.save(mainIni, "fishki.ini")

local renderWindow = imgui.new.bool(false)
local close_status = imgui.new.bool(true)
local menu_show = false
local menu_alpha = 0.0

local clickerState = false
local isWaitingForSpawn = false
local fisheyeLocked = false
local limitWasDown = false
local bindWaiting = nil

local active67 = false
local BLEND = 4.0

local fov_val = imgui.new.float(mainIni.settings.fisheye_fov)
local dlg_style_val = imgui.new.int(mainIni.settings.dialog_style)
local autotax_interval_val = imgui.new.int(mainIni.settings.autotax_interval)

local captchaState = false
local captime = nil
local t = 0
local captcha = ''
local captchaTable = {}

local captcha_dialog_id = nil
local real_captcha_start = 0
local last_esc_time = os.clock()
local last_cef_check = os.clock()
local last_autotax_time = os.clock()

local toggleCefFn = nil
local areEnabledFn = nil

local function check_and_update(is_manual)
    lua_thread.create(function()
        local status, response = pcall(requests.get, JSON_URL)
        if status and response and response.status_code == 200 then
            local ok, version_info = pcall(json.decode, response.text)
            if ok and version_info and version_info.latest_version and version_info.download_url then
                if version_info.latest_version ~= thisScript().version then
                    sampAddChatMessage("{24ff86}[MultiMenu] {FFFFFF}Доступно обновление! Устанавливаем версию " .. version_info.latest_version, -1)
                    local dl_status, dl_resp = pcall(requests.get, version_info.download_url)
                    if dl_status and dl_resp and dl_resp.status_code == 200 then
                        local file = io.open("moonloader\\" .. SCRIPT_FILENAME, "wb")
                        if file then
                            file:write(dl_resp.content or dl_resp.text)
                            file:close()
                            sampAddChatMessage("{24ff86}[MultiMenu] {FFFFFF}Успешно! Была установлена новая версия. Перезапустите скрипт (/reload).", -1)
                        else
                            sampAddChatMessage("{FF6060}[MultiMenu] Ошибка: не удалось записать файл скрипта.", -1)
                        end
                    else
                        sampAddChatMessage("{FF6060}[MultiMenu] Ошибка скачивания файла обновления.", -1)
                    end
                else
                    if is_manual then
                        sampAddChatMessage("{24ff86}[MultiMenu] {FFFFFF}У вас установлена самая новая версия скрипта.", -1)
                    end
                end
            else
                if is_manual then sampAddChatMessage("{FF6060}[MultiMenu] Ошибка чтения данных из JSON.", -1) end
            end
        else
            if is_manual then sampAddChatMessage("{FF6060}[MultiMenu] Не удалось подключиться к серверу обновлений.", -1) end
        end
    end)
end

local function loadDll()
    local hDll = kernel32.LoadLibraryA('vorbisFile.dll')
    if hDll == nil or hDll == ffi.cast('void*', 0) then return nil, nil end
    local fnToggle = kernel32.GetProcAddress(hDll, 'ToggleCefDialogs')
    local fnAreEnabled = kernel32.GetProcAddress(hDll, 'AreCefDialogsEnabled')
    if fnToggle == nil or fnToggle == ffi.cast('void*', 0) then return nil, nil end
    if fnAreEnabled == nil or fnAreEnabled == ffi.cast('void*', 0) then return nil, nil end
    return ffi.cast('void(__cdecl*)(int)', fnToggle), ffi.cast('int(__cdecl*)(void)', fnAreEnabled)
end

local FIX_JS = [[
try {
  if (window && window.cef && typeof window.cef.HandleGameMenu === 'function') {
    window.cef.HandleGameMenu(false);
  }
  if (typeof window.executeEvent === 'function') {
    window.executeEvent('event.mainMenu.setMainMenuDisabled', `[true]`);
  }
} catch (e) {}
]]

local function evalcef(code, encoded)
    encoded = encoded or 0
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)
    raknetBitStreamWriteInt32(bs, 0)
    raknetBitStreamWriteInt16(bs, #code)
    raknetBitStreamWriteInt8(bs, encoded)
    raknetBitStreamWriteString(bs, code)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
end

local function applyOldEscFix()
    evalcef(("(() => {%s})()"):format(FIX_JS))
end

function waitForDialog(dialogId, timeout)
    local end_time = os.clock() * 1000 + timeout
    while end_time > os.clock() * 1000 do
        wait(100)
        if sampIsDialogActive() and sampGetCurrentDialogId() == dialogId then return true end
    end
    return false
end

function waitForAnyDialog(timeout)
    local end_time = os.clock() * 1000 + timeout
    while end_time > os.clock() * 1000 do
        wait(100)
        if sampIsDialogActive() then return sampGetCurrentDialogId() end
    end
    return nil
end

function cefSendRaw(data)
    local bs = raknetNewBitStream()
    for _, val in ipairs(data) do raknetBitStreamWriteInt8(bs, val) end
    raknetSendBitStreamEx(bs, 1, 7, 1)
    raknetDeleteBitStream(bs)
end

function cefSend(data)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, string.len(data))
    raknetBitStreamWriteString(bs, data)
    raknetSendBitStreamEx(bs, 1, 7, 1)
    raknetDeleteBitStream(bs)
end

function setArizonaDialogsStyle(style)
    if type(style) ~= "number" then return end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 53)
    raknetBitStreamWriteInt8(bs, style)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
end

function doPayTaxes()
    sampAddChatMessage("{24ff86}[MultiTool]{FFFFFF} Начинаю оплату...", -1)
    sampSendChat("/phone")
    wait(1000)
    cefSend("launchedApp|24")
    sampAddChatMessage("{24ff86}[MultiTool]{FFFFFF} Открываю телефон...", -1)

    if not waitForDialog(6565, 5000) then
        sampAddChatMessage("{FF6060}[MultiTool] Ошибка: телефон не открылся", -1)
        return
    end

    wait(300)
    sampSendDialogResponse(6565, 1, 4, "")

    local var_5_0 = waitForAnyDialog(5000)

    if not var_5_0 then
        sampAddChatMessage("{FF6060}[MultiTool] Ошибка: диалог налогов не появился", -1)
        return
    end

    wait(300)

    if var_5_0 == 15252 then
        sampSendDialogResponse(15252, 1, 0, "")
        sampAddChatMessage("{90EE90}[MultiTool] Налоги оплачены!", -1)
    else
        sampCloseCurrentDialogWithButton(1)
        sampAddChatMessage("{90EE90}[MultiTool] Все налоги уже оплачены!", -1)
    end

    sampAddChatMessage("{FFFFFF}[MultiTool] Проверяю отель...", -1)

    if not waitForDialog(6565, 5000) then
        wait(500)
        cefSend("launchedApp|24")

        if not waitForDialog(6565, 5000) then
            sampAddChatMessage("{FF6060}[MultiTool] Ошибка: меню телефона не открылось", -1)
            return
        end
    end

    wait(300)
    sampSendDialogResponse(6565, 1, 12, "")

    if not waitForDialog(26155, 5000) then
        sampAddChatMessage("{FF6060}[MultiTool] Ошибка: диалог отеля не появился", -1)
        return
    end

    wait(300)

    local var_5_1 = sampGetDialogText():match("(%d+)%s")

    if var_5_1 and tonumber(var_5_1) >= 12 then
        sampSendDialogResponse(26155, 1, 0, "")
        sampAddChatMessage("{90EE90}[MultiTool] Отель продлён на 12 часов!", -1)
    else
        sampSendDialogResponse(26155, 0, 0, "")
        sampAddChatMessage("{FFAA60}[MultiTool] Отель: можно продлить только на " .. (var_5_1 or "0") .. " ч. (нужно 12)", -1)
    end

    wait(300)
    cefSendRaw({220, 0, 27, 0})
    wait(500)
    sampAddChatMessage("{FFFFFF}[MultiTool] Открываю /fammenu...", -1)
    sampSendChat("/fammenu")
    wait(1000)
    cefSend("familyMenu.apart.payTax")

    if not waitForDialog(27806, 5000) then
        sampAddChatMessage("{FF6060}[MultiTool] Ошибка: диалог квартиры не появился", -1)
        return
    end

    wait(300)

    local var_5_2 = sampGetDialogText():match("%$([%d,%.]+)")
    local var_5_3 = var_5_2 and var_5_2:gsub("[,%.%s]", "") or nil

    if var_5_3 and tonumber(var_5_3) > 0 then
        sampSendDialogResponse(27806, 1, 0, var_5_3)
        sampAddChatMessage("{90EE90}[MultiTool] Налог на квартиру оплачен: $" .. var_5_3, -1)
    else
        sampCloseCurrentDialogWithButton(0)
        sampAddChatMessage("{90EE90}[MultiTool] Налог на квартиру: $0", -1)
    end

    wait(500)
    cefSend("familyMenu.exit")
    wait(1000)
    sampAddChatMessage("{90EE90}[MultiTool] Полный цикл оплаты завершен!", -1)
end

ae.onArizonaDisplay = function(packet)
    lastServerId = packet.server_id or 0
    local status, decodedStatus = pcall(ae.decode, packet)
    if not status or not decodedStatus then return end

    local eventName = packet.event
    local blockEvents = {
        ["event.radialMenu.items"] = true,
        ["event.setActiveView"]    = true,
        ["cef.toggleServerCursor"] = true
    }

    local automating = isAutomatingSport or isAutomatingDrift

    if automating and blockEvents[eventName] then
        if eventName == "event.radialMenu.items" then
            local data = packet.json
            local items = data[1] or data.items or data
            if type(items) ~= "table" then items = {} end

            local targetId, cancelId, nextId = nil, nil, nil

            for _, item in ipairs(items) do
                local title = item.title or ""
                local lowerTitle = title:lower()
                
                if isAutomatingSport then
                    if lowerTitle:find("sport") or lowerTitle:find(u8:encode("спорт")) then
                        targetId = item.id or item.uid
                    elseif lowerTitle:find("comfort") or lowerTitle:find(u8:encode("комфорт")) then
                        cancelId = item.id or item.uid
                    end
                elseif isAutomatingDrift then
                    if lowerTitle:find("drift") or lowerTitle:find(u8:encode("дрифт")) then
                        targetId = item.id or item.uid
                    end
                end
                
                if lowerTitle:find(u8:encode("вперед")) or lowerTitle:find("vpered") or lowerTitle:find("forward") then
                    nextId = item.id or item.uid
                end
            end

            if targetId then
                ae.send("onArizonaSend", { id = 18, text = "radialMenu.useAction | " .. targetId, server_id = lastServerId })
                lua_thread.create(function()
                    wait(50)
                    ae.send("onArizonaSendKey", { key = 27, _unknown = 0 })
                    if isAutomatingSport then isAutomatingSport = false end
                    if isAutomatingDrift then isAutomatingDrift = false end
                end)
                return false
            elseif cancelId and isAutomatingSport then
                lua_thread.create(function()
                    wait(50)
                    ae.send("onArizonaSendKey", { key = 27, _unknown = 0 })
                    isAutomatingSport = false
                end)
                return false
            elseif nextId then
                ae.send("onArizonaSend", { id = 18, text = "radialMenu.useAction | " .. nextId, server_id = lastServerId })
                return false
            else
                ae.send("onArizonaSendKey", { key = 27, _unknown = 0 })
                if isAutomatingSport then isAutomatingSport = false end
                if isAutomatingDrift then isAutomatingDrift = false end
                return false
            end
        end
        return false
    end
end

ae.onArizonaSendKey = function(packet)
    local automating = isAutomatingSport or isAutomatingDrift
    if automating and packet.key == 82 and not scriptKeyAction then return false end
end

local function getKeyName(id)
    if id == 0 or id == nil then return "Нет" end
    local name = vkeys.id_to_name(id)
    if name then return name:gsub("VK_", "") else return tostring(id) end
end

local function getFullKeyName(k, m)
    if k == 0 or k == nil then return "Нет" end
    local kname = getKeyName(k)
    if m and m ~= 0 then return getKeyName(m) .. " + " .. kname end
    return kname
end

local function checkBind(k, m)
    if k == 0 or k == nil then return false end
    if m and m ~= 0 then
        if not isKeyDown(m) then return false end
    end
    return wasKeyPressed(k)
end

local function checkBindDown(k, m)
    if k == 0 or k == nil then return false end
    if m and m ~= 0 then
        if not isKeyDown(m) then return false end
    end
    return isKeyDown(k)
end

local function removeTextdraws()
    if t > 0 then
        for i = 1, t do sampTextdrawDelete(i) end
        t = 0
        captcha = ''
        captime = nil
    end
end

local function GenerateTextDraw(id, PosX, PosY)
    if id == 0 then
        t = t + 1
        sampTextdrawCreate(t, "LD_SPAC:white", PosX - 5, PosY + 7)
        sampTextdrawSetLetterSizeAndColor(t, 0, 3, 0x80808080)
        sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX+5, 0.000000)
    elseif id == 1 then
        for i = 0, 1 do
            t = t + 1
            local offsetX, offsetBX = (i == 0) and 3 or -3, (i == 0) and 15 or -15
            sampTextdrawCreate(t, "LD_SPAC:white", PosX - offsetX, PosY)
            sampTextdrawSetLetterSizeAndColor(t, 0, 4.5, 0x80808080)
            sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX-offsetBX, 0.000000)
        end
    elseif id == 2 then
        for i = 0, 1 do
            t = t + 1
            local offsetX, offsetY, offsetBX = (i == 0) and -8 or 6, (i == 0) and 7 or 25, (i == 0) and 15 or -15
            sampTextdrawCreate(t, "LD_SPAC:white", PosX - offsetX, PosY + offsetY)
            sampTextdrawSetLetterSizeAndColor(t, 0, 0.8, 0x80808080)
            sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX-offsetBX, 0.000000)
        end
    elseif id == 3 then
        for i = 0, 1 do
            t = t + 1
            local offsetY = (i == 0) and 7 or 25
            sampTextdrawCreate(t, "LD_SPAC:white", PosX+10, PosY+offsetY)
            sampTextdrawSetLetterSizeAndColor(t, 0, 1, 0x80808080)
            sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX-15, 0.000000)
        end
    elseif id == 4 then
        for i = 0, 1 do
            t = t + 1
            local size, offsetX, offsetY, offsetBX = (i == 0) and 1.8 or 2, (i == 0) and -10 or -10, (i == 0) and 0 or 25, (i == 0) and 10 or 15
            sampTextdrawCreate(t, "LD_SPAC:white", PosX - offsetX, PosY + offsetY)
            sampTextdrawSetLetterSizeAndColor(t, 0, size, 0x80808080)
            sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX-offsetBX, 0.000000)
        end
    elseif id == 5 then
        for i = 0, 1 do
            t = t + 1
            local size, offsetX, offsetY, offsetBX = (i == 0) and 0.8 or 1, (i == 0) and 8 or -10, (i == 0) and 7 or 25, (i == 0) and -15 or 15
            sampTextdrawCreate(t, "LD_SPAC:white", PosX - offsetX, PosY + offsetY)
            sampTextdrawSetLetterSizeAndColor(t, 0, size, 0x80808080)
            sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX-offsetBX, 0.000000)
        end
    elseif id == 6 then
        for i = 0, 1 do
            t = t + 1
            local size, offsetX, offsetY, offsetBX = (i == 0) and 0.8 or 1, (i == 0) and 7.5 or -10, (i == 0) and 7 or 25, (i == 0) and -15 or 10
            sampTextdrawCreate(t, "LD_SPAC:white", PosX - offsetX, PosY + offsetY)
            sampTextdrawSetLetterSizeAndColor(t, 0, size, 0x80808080)
            sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX-offsetBX, 0.000000)
        end
    elseif id == 7 then
        t = t + 1
        sampTextdrawCreate(t, "LD_SPAC:white", PosX - 13, PosY + 7)
        sampTextdrawSetLetterSizeAndColor(t, 0, 3.75, 0x80808080)
        sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX+5, 0.000000)
    elseif id == 8 then
        for i = 0, 1 do
            t = t + 1
            local offsetY = (i == 0) and 7 or 25
            sampTextdrawCreate(t, "LD_SPAC:white", PosX+10, PosY+offsetY)
            sampTextdrawSetLetterSizeAndColor(t, 0, 1, 0x80808080)
            sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX-10, 0.000000)
        end
    elseif id == 9 then
        for i = 0, 1 do
            t = t + 1
            local offsetY, offsetBX = (i == 0) and 6 or 25, (i == 0) and 10 or 15
            sampTextdrawCreate(t, "LD_SPAC:white", PosX+10, PosY+offsetY)
            sampTextdrawSetLetterSizeAndColor(t, 0, 1, 0x80808080)
            sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, PosX-offsetBX, 0.000000)
        end
    end
end

local function showCaptcha()
    removeTextdraws()
    t = t + 1
    sampTextdrawCreate(t, "LD_SPAC:white", 220, 120)
    sampTextdrawSetLetterSizeAndColor(t, 0, 6.5, 0x80808080)
    sampTextdrawSetBoxColorAndSize(t, 1, 0xFF1A2432, 380, 0.000000)
       
    t = t + 1
    sampTextdrawCreate(t, "LD_SPAC:white", 225, 125)
    sampTextdrawSetLetterSizeAndColor(t, 0, 5.5, 0x80808080)
    sampTextdrawSetBoxColorAndSize(t, 1, 0xFF759DA3, 375, 0.000000)
    local nextPos = -30.0;
       
    math.randomseed(os.time())
    for i = 1, 4 do
        local a = math.random(0, 9)
        table.insert(captchaTable, a)
        captcha = captcha..a
    end
       
    for i = 0, 4 do
        nextPos = nextPos + 30
        t = t + 1
        sampTextdrawCreate(t, "usebox", 240 + nextPos, 130)
        sampTextdrawSetLetterSizeAndColor(t, 0, 4.5, 0x80808080)
        sampTextdrawSetBoxColorAndSize(t, 1, 0xFF1A2432, 30, 25.000000)
        sampTextdrawSetAlign(t, 2)
        if i < 4 then GenerateTextDraw(captchaTable[i + 1], 240 + nextPos, 130)
        else GenerateTextDraw(0, 240 + nextPos, 130) end
    end
    captchaTable = {}
    
    local bestStr = (mainIni.settings.best_captcha_time > 0) and string.format("%.3f", mainIni.settings.best_captcha_time) or "нет"
    sampShowDialog(8813, '{F89168}Проверка на робота', string.format('{FFFFFF}Введите {C6FB4A}5{FFFFFF} символов.\n{C0C0C0}Рекорд: {24ff86}%s', bestStr), 'Принять', 'Отмена', 1)
    captime = os.clock()
end

function onWindowMessage(msg, wparam, lparam)
    if msg == 0x100 then
        if wparam == vkeys.VK_ESCAPE and menu_show then
            menu_show = false
            consumeWindowMessage(true, false)
            return
        end

        if mainIni.toggles.antibpwb and not (sampIsChatInputActive() or sampIsDialogActive() or isSampfuncsConsoleActive()) then
            if wparam == 77 or wparam == 0x42 then
                consumeWindowMessage(true, true)
            end
        end
        if mainIni.toggles.oldesc and wparam == vkeys.VK_ESCAPE then
            applyOldEscFix()
        end
    end
end

-- Единый обработчик диалогов: здесь и теги денег, и старые стили, и капча
function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    local isModified = false
    
    -- 1. Твой нормальный фикс для денег
    if title:find(":CASHV:") or title:find(":CASH:") then
        title = title:gsub(":CASHV:", "VC$")
        title = title:gsub(":CASH:", "SA$")
        isModified = true
    end
    
    if text:find(":CASHV:") or text:find(":CASH:") then
        text = text:gsub(":CASHV:", "VC$")
        text = text:gsub(":CASH:", "SA$")
        isModified = true
    end

    -- 2. Конвертация стилей диалогов (если включено в настройках)
    if mainIni.toggles.dlgstyle_enabled and style >= 6 then
        style = 1
        if dialogId == MARKET_DIALOG_ID then style = 5 end
        isModified = true
    end
    
    if isModified then
        return {dialogId, style, title, button1, button2, text}
    end

    if title:find("Проверка на робота") then
        captcha_dialog_id = dialogId
        real_captcha_start = os.clock()
    end
end

imgui.OnInitialize(function()
    local style = imgui.GetStyle()
    local colors = style.Colors
    local clr = imgui.Col
    local ImVec4 = imgui.ImVec4

    style.WindowRounding = 10.0
    style.ChildRounding = 6.0
    style.FrameRounding = 6.0
    style.PopupRounding = 6.0
    style.ScrollbarRounding = 6.0
    style.GrabRounding = 6.0
    style.ButtonTextAlign = imgui.ImVec2(0.5, 0.5)

    colors[clr.WindowBg]      = ImVec4(0.08, 0.06, 0.12, 0.85)
    colors[clr.ChildBg]       = ImVec4(0.12, 0.09, 0.18, 0.60)
    colors[clr.PopupBg]       = ImVec4(0.10, 0.08, 0.15, 0.90)
    colors[clr.Border]        = ImVec4(0.45, 0.25, 0.65, 0.50)
    colors[clr.TitleBg]       = ImVec4(0.18, 0.10, 0.28, 0.90)
    colors[clr.TitleBgActive] = ImVec4(0.25, 0.13, 0.38, 0.95)
    colors[clr.Button]        = ImVec4(0.35, 0.18, 0.55, 0.85)
    colors[clr.ButtonHovered] = ImVec4(0.45, 0.24, 0.70, 0.95)
    colors[clr.ButtonActive]  = ImVec4(0.30, 0.15, 0.48, 0.90)
    colors[clr.Tab]           = ImVec4(0.20, 0.11, 0.32, 0.80)
    colors[clr.TabHovered]    = ImVec4(0.45, 0.24, 0.70, 0.90)
    colors[clr.TabActive]     = ImVec4(0.35, 0.18, 0.55, 1.00)
    colors[clr.CheckMark]     = ImVec4(0.65, 0.35, 0.95, 1.00)
    colors[clr.FrameBg]       = ImVec4(0.18, 0.12, 0.26, 0.70)
    colors[clr.FrameBgHovered]= ImVec4(0.24, 0.16, 0.35, 0.80)
    colors[clr.FrameBgActive] = ImVec4(0.30, 0.20, 0.44, 0.90)
    colors[clr.SliderGrab]    = ImVec4(0.55, 0.28, 0.85, 0.90)
    colors[clr.SliderGrabActive] = ImVec4(0.65, 0.35, 0.95, 1.00)
    colors[clr.Separator]     = ImVec4(0.40, 0.22, 0.60, 0.60)
end)

imgui.OnFrame(function() return renderWindow[0] end, function(player)
    imgui.SetNextWindowSize(imgui.ImVec2(540, 350), imgui.Cond.Always)
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, menu_alpha)
    
    if imgui.Begin(u8"Мульти-Скрипт Меню (by 369Miko)", close_status, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize) then
        
        if not close_status[0] then
            menu_show = false
            close_status[0] = true
        end

        local footerHeight = 28
        
        if imgui.BeginChild("MainContentArea", imgui.ImVec2(0, -footerHeight), false) then
            
            imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(2, 4))
            
            local availW = imgui.GetContentRegionAvail().x
            local pad = math.floor((availW - (75 * 3)) / 6)
            if pad < 2 then pad = 2 end
            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(pad, 6))
            
            if imgui.BeginTabBar("MultiMenuTabs", imgui.TabBarFlags_FittingPolicyResizeDown) then

                -- ВКЛАДКА 1: ИНФОРМАЦИЯ
                if imgui.BeginTabItem(u8"Информация", nil, 0) then
                    imgui.Spacing()
                    imgui.TextColored(imgui.ImVec4(0.75, 0.45, 0.95, 1.0), u8"Добро пожаловать в Multi-Скрипт!")
                    imgui.Spacing()
                    imgui.Separator()
                    imgui.Spacing()
                    imgui.Text(u8"Активная версия скрипта: " .. thisScript().version)
                    imgui.Text(u8"Скрипт создал: 369Miko")
                    imgui.Text(u8"Обратная связь: dc 369miko")
                    imgui.Spacing()
                    
                    if imgui.Button(u8"Проверить обновление", imgui.ImVec2(-1, 24)) then
                        check_and_update(true)
                    end
                    
                    imgui.Spacing()
                    imgui.Separator()
                    imgui.Spacing()
                    imgui.TextColored(imgui.ImVec4(0.85, 0.75, 0.95, 1.0), u8"Команды скрипта:")
                    imgui.Text(u8"• /fmenu — открыть/закрыть меню")
                    imgui.Text(u8"• /w — быстрая оплата налогов и отеля")
                    imgui.TextColored(imgui.ImVec4(0.14, 1.0, 0.52, 1), u8"Тренировка капчи: команда /asd (активация N англ.)")
                    imgui.TextColored(imgui.ImVec4(0.67, 0.29, 0.32, 1), u8"При отключении Old Esc Restore и Старые диалоги нужен /rec!")
                    imgui.TextColored(imgui.ImVec4(1.0, 0.3, 0.3, 1.0), u8"Автор скрипта псих не пишите /67")
                    imgui.Spacing()
                    imgui.Separator()
                    imgui.Spacing()
                    imgui.TextWrapped(u8"Описание: Удобный мульти-инструмент для Arizona RP, включающий в себя полезные вспомогательные фишки, настройку интерфейса, автоматизацию и тренировку капчи.")
                    imgui.EndTabItem()
                end

                -- ВКЛАДКА 2: ФУНКЦИИ
                if imgui.BeginTabItem(u8"Функции", nil, 0) then
                    imgui.Spacing()
                    
                    local function drawCheckbox(name, toggle_key)
                        local state = imgui.new.bool(mainIni.toggles[toggle_key])
                        if imgui.Checkbox(u8(name), state) then
                            mainIni.toggles[toggle_key] = state[0]
                            inicfg.save(mainIni, "fishki.ini")
                            
                            if toggle_key == "dlgstyle_enabled" then
                                if state[0] then
                                    if toggleCefFn then pcall(function() toggleCefFn(0) end) end
                                else
                                    if toggleCefFn then pcall(function() toggleCefFn(1) end) end
                                end
                            end
                        end
                    end

                    imgui.Columns(2, "FuncColumns", false)
                    
                    drawCheckbox("Sharik", "balloon")
                    drawCheckbox("Auto-Bodycam", "bodycam")
                    drawCheckbox("UnFreeze Camera", "unfreeze")
                    drawCheckbox("Global FOV", "fisheye")
                    drawCheckbox("Hand-Run", "hand")
                    drawCheckbox("Limit", "limit")
                    
                    imgui.NextColumn()
                    
                    drawCheckbox("Sbiv piss", "anim68")
                    drawCheckbox("Auto-Sport (ARZ)", "autosport")
                    drawCheckbox("Auto-Drift (ARZ)", "autodrift")
                    drawCheckbox("Anti-WBook & BP", "antibpwb")
                    drawCheckbox("Old ESC Restore", "oldesc")
                    drawCheckbox("Старые диалоги (CEF Off)", "dlgstyle_enabled")
                    
                    imgui.Columns(1) 

                    if mainIni.toggles.fisheye then
                        imgui.Spacing()
                        imgui.PushItemWidth(-1)
                        if imgui.SliderFloat(u8"##FOV", fov_val, 70.0, 110.0, u8"FOV: %.1f") then
                            mainIni.settings.fisheye_fov = fov_val[0]
                            inicfg.save(mainIni, "fishki.ini")
                            cameraSetLerpFov(mainIni.settings.fisheye_fov, mainIni.settings.fisheye_fov, 1000, 1)
                        end
                        imgui.PopItemWidth()
                    end

                    if mainIni.toggles.dlgstyle_enabled then
                        imgui.Spacing()
                        imgui.Text(u8"Выбор стиля (1-5):")
                        imgui.PushItemWidth(-1)
                        if imgui.SliderInt("##DlgStyle", dlg_style_val, 1, 5) then
                            mainIni.settings.dialog_style = dlg_style_val[0]
                            inicfg.save(mainIni, "fishki.ini")
                            setArizonaDialogsStyle(dlg_style_val[0])
                        end
                        imgui.PopItemWidth()
                    end

                    imgui.EndTabItem()
                end

                -- ВКЛАДКА 3: БИНДЕР
                if imgui.BeginTabItem(u8"Биндер", nil, 0) then
                    imgui.Spacing()
                    imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1), u8"Настройка клавиш быстрого доступа:")
                    imgui.Spacing()
                    imgui.Separator()
                    imgui.Spacing()

                    local function drawBindRow(label, bind_key)
                        imgui.Text(u8(label))
                        imgui.SameLine(250)
                        local btn_text = (bindWaiting == bind_key) and u8"< Жду кнопку >" or string.format(u8"[%s]", getFullKeyName(mainIni.keys[bind_key], mainIni.mods[bind_key]))
                        if imgui.Button(btn_text .. "##" .. bind_key, imgui.ImVec2(180, 20)) then
                            bindWaiting = bind_key
                        end
                    end

                    drawBindRow("Шар (Balloon)", "balloon")
                    drawBindRow("UnFreeze Camera", "unfreeze")
                    drawBindRow("Рука (Hand-Run)", "hand")
                    drawBindRow("Лимит скорости", "limit")
                    drawBindRow("Sbiv piss", "anim68")

                    imgui.Spacing()
                    imgui.Separator()
                    imgui.Spacing()

                    local autotax_state = imgui.new.bool(mainIni.toggles.autotax)
                    if imgui.Checkbox(u8"Авто-оплата налогов", autotax_state) then
                        mainIni.toggles.autotax = autotax_state[0]
                        inicfg.save(mainIni, "fishki.ini")
                    end

                    if mainIni.toggles.autotax then
                        imgui.Spacing()
                        imgui.PushItemWidth(-1)
                        if imgui.SliderInt(u8"##AutoTaxInterval", autotax_interval_val, 1, 60, u8"Интервал: %d мин.") then
                            mainIni.settings.autotax_interval = autotax_interval_val[0]
                            inicfg.save(mainIni, "fishki.ini")
                        end
                        imgui.PopItemWidth()
                    end

                    imgui.Spacing()
                    imgui.Separator()
                    imgui.Spacing()

                    if imgui.Button(u8"Оплатить налоги сейчас", imgui.ImVec2(-1, 24)) then
                        lua_thread.create(doPayTaxes)
                    end

                    imgui.Spacing()
                    imgui.Separator()

                    if bindWaiting then
                        imgui.TextColored(imgui.ImVec4(1, 0.4, 0.4, 1), u8"Нажмите сочетание (Alt/Ctrl/Shift) + нужную кнопку")
                    end

                    imgui.EndTabItem()
                end

                imgui.EndTabBar()
            end
            imgui.PopStyleVar()
            imgui.EndChild()
        end

        -- Нижняя панель
        imgui.Separator()
        local playerName = (isSampAvailable() and sampGetPlayerNickname(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)))) or "Player"
        local serverIp, serverPort = (isSampAvailable() and sampGetCurrentServerAddress()) or "127.0.0.1", 7777
        local ping = (isSampAvailable() and sampGetPlayerPing(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)))) or 0
        local fps = math.floor(imgui.GetIO().Framerate)
        local footerText = string.format("Ник: %s | Сервер: %s:%d | Пинг: %d | FPS: %d", playerName, serverIp, serverPort, ping, fps)
        imgui.TextColored(imgui.ImVec4(0.7, 0.5, 0.9, 1), u8(footerText))

        imgui.End()
    end
    
    imgui.PopStyleVar()
end)

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    toggleCefFn, areEnabledFn = loadDll()

    if mainIni.toggles.oldesc then
        applyOldEscFix()
    end

    if mainIni.toggles.dlgstyle_enabled and toggleCefFn then
        pcall(function() toggleCefFn(0) end)
    end

    check_and_update(false)

    sampRegisterChatCommand("fmenu", function() menu_show = not menu_show end)
    sampRegisterChatCommand("w", function() lua_thread.create(doPayTaxes) end)
    
    sampRegisterChatCommand("67", function()
        active67 = not active67
        if active67 then
            sampAddChatMessage("ЫЫ СЫКС СЕВЕН ХЫХЫ", 0x00FF00)
        else
            sampAddChatMessage("Я БОЛШЕ НЕ СЫКС СЕВЕН ХНЫК ХНЫК", 0xFF0000)
            clearCharTasksImmediately(PLAYER_PED)
        end
    end)

    sampRegisterChatCommand("asd", function() 
        captchaState = not captchaState
        sampAddChatMessage((captchaState and '{24ff86}[Captcha{24ff86}] {ffffff}Тренировка капчи включена.' or '{24ff86}[Captcha{24ff86}] {ffffff}Тренировка капчи выключена.'), -1)
    end)
    
    sampAddChatMessage(string.format("{24ff86}[MultiTool {d1b02c}%s {ffffff}by {C0C0C0}369Miko{24ff86}] {ffffff}Успешно загружен! Команда: /fmenu", thisScript().version), -1)

    if not hasAnimationLoaded("GHANDS") then requestAnimation("GHANDS") end
    if not hasAnimationLoaded("PED") then requestAnimation("PED") end

    lua_thread.create(function()
        while true do
            wait(0)
            if active67 then
                taskPlayAnim(PLAYER_PED, "FUCKU", "PED", 4.0, true, true, true, false, -1)
                wait(250)
                if active67 then
                    taskPlayAnim(PLAYER_PED, "GSIGN2LH", "GHANDS", 4.0, true, true, true, false, -1)
                    wait(350)
                end
            end
        end
    end)

    lua_thread.create(function()
        while true do
            wait(2000)
            if areEnabledFn then
                local ok2, result = pcall(areEnabledFn)
                if ok2 and result ~= 0 and mainIni.toggles.dlgstyle_enabled then
                    pcall(function() toggleCefFn(0) end)
                end
            end
        end
    end)

    while true do
        wait(0)
        
        if mainIni.toggles.autotax then
            local current_time = os.clock()
            local interval_sec = mainIni.settings.autotax_interval * 60
            if current_time - last_autotax_time >= interval_sec then
                last_autotax_time = current_time
                if not (sampIsChatInputActive() or sampIsDialogActive()) then
                    lua_thread.create(doPayTaxes)
                end
            end
        else
            last_autotax_time = os.clock()
        end

        if mainIni.toggles.oldesc then
            if os.clock() - last_esc_time >= 10.0 then
                applyOldEscFix()
                last_esc_time = os.clock()
            end
        end

        if captchaState then
            if testCheat("n") and not sampIsChatInputActive() and not sampIsDialogActive() then showCaptcha() end
            local result, button, list, input = sampHasDialogRespond(8813)
            if result then
                if button == 1 then
                    local current_time = os.clock() - captime
                    if input == captcha..'0' then 
                        local is_new_record = false
                        if mainIni.settings.best_captcha_time == 0 or current_time < mainIni.settings.best_captcha_time then
                            mainIni.settings.best_captcha_time = current_time
                            inicfg.save(mainIni, "fishki.ini")
                            is_new_record = true
                        end
                        
                        if is_new_record then
                            sampAddChatMessage(string.format('{24ff86}НОВЫЙ РЕКОРД: {24ff86}%.3f', current_time), -1)
                        else
                            sampAddChatMessage(string.format('{24ff86}Код верный {C0C0C0}[%.3f] (Рекорд: %.3f)', current_time, mainIni.settings.best_captcha_time), -1)
                        end
                    else 
                        sampAddChatMessage(string.format('{ff0000}Неверный код! {C0C0C0}[%.3f] ('..captcha..'0|'..input..')', current_time), -1) 
                    end
                end
                removeTextdraws()
            end   
        end

        if menu_show and menu_alpha < 1.0 then
            menu_alpha = menu_alpha + 0.04
            if menu_alpha >= 1.0 then menu_alpha = 1.0 end
        elseif not menu_show and menu_alpha > 0.0 then
            menu_alpha = menu_alpha - 0.04
            if menu_alpha <= 0.0 then menu_alpha = 0.0 end
        end
        renderWindow[0] = (menu_alpha > 0.0)

        local isInputActive = sampIsChatInputActive() or sampIsDialogActive() or sampIsCursorActive() or isSampfuncsConsoleActive() or sampIsScoreboardOpen()

        if bindWaiting then
            for i = 1, 255 do
                if wasKeyPressed(i) then
                    if i == vkeys.VK_ESCAPE then
                        bindWaiting = nil
                    elseif i ~= vkeys.VK_LBUTTON then
                        if i ~= 0x10 and i ~= 0x11 and i ~= 0x12 and i ~= 0xA0 and i ~= 0xA1 and i ~= 0xA2 and i ~= 0xA3 and i ~= 0xA4 and i ~= 0xA5 then
                            local mod = 0
                            if isKeyDown(0x12) or isKeyDown(0xA4) or isKeyDown(0xA5) then mod = 0x12
                            elseif isKeyDown(0x11) or isKeyDown(0xA2) or isKeyDown(0xA3) then mod = 0x11
                            elseif isKeyDown(0x10) or isKeyDown(0xA0) or isKeyDown(0xA1) then mod = 0x10
                            end
                            
                            mainIni.keys[bindWaiting] = i
                            mainIni.mods[bindWaiting] = mod
                            inicfg.save(mainIni, "fishki.ini")
                            bindWaiting = nil
                        end
                    end
                    break
                end
            end
        end

        if not bindWaiting then
            if mainIni.toggles.balloon then
                if checkBind(mainIni.keys.balloon, mainIni.mods.balloon) and not isInputActive then
                    sampSendChat("/balloon")
                end
                
                if clickerState then
                    local command = "clickMinigame"
                    local bs = raknetNewBitStream()
                    raknetBitStreamWriteInt8(bs, 220)
                    raknetBitStreamWriteInt8(bs, 18)
                    raknetBitStreamWriteInt16(bs, #command)
                    raknetBitStreamWriteString(bs, command)
                    raknetBitStreamWriteInt32(bs, 0)
                    raknetSendBitStream(bs)
                    raknetDeleteBitStream(bs)
                end
            end

            if mainIni.toggles.unfreeze and checkBind(mainIni.keys.unfreeze, mainIni.mods.unfreeze) and not isInputActive then
                local bs = raknetNewBitStream()
                raknetEmulRpcReceiveBitStream(162, bs)
                raknetDeleteBitStream(bs)
                freezeCharPosition(PLAYER_PED, false)
                setPlayerControl(player, true)
            end

            if mainIni.toggles.fisheye then
                cameraSetLerpFov(mainIni.settings.fisheye_fov, mainIni.settings.fisheye_fov, 1000, 1)
                fisheyeLocked = true
            else
                if fisheyeLocked then
                    cameraSetLerpFov(70.0, 70.0, 1000, 1)
                    fisheyeLocked = false
                end
            end

            if mainIni.toggles.hand and checkBindDown(mainIni.keys.hand, mainIni.mods.hand) and isCharOnFoot(PLAYER_PED) and not isInputActive then
                if isCharPlayingAnim(PLAYER_PED, "gsign1") then
                    clearCharTasksImmediately(PLAYER_PED)
                else
                    taskPlayAnimNonInterruptable(PLAYER_PED, "gsign1", "GHANDS", 4.0, true, false, false, false, -1)
                end
                while isKeyDown(mainIni.keys.hand) do wait(0) end
            end

            if mainIni.toggles.anim68 and checkBindDown(mainIni.keys.anim68, mainIni.mods.anim68) and not isInputActive then
                sampSetSpecialAction(68)
                while isKeyDown(mainIni.keys.anim68) do wait(0) end
            end

            local limitDown = checkBindDown(mainIni.keys.limit, mainIni.mods.limit)
            if mainIni.toggles.limit and limitDown and not limitWasDown and not isInputActive then
                if isCharInAnyCar(PLAYER_PED) then
                    sampSendChat("/limit 30")
                    wait(100)
                    sampSendChat("/limit 0")
                end
            end
            limitWasDown = limitDown
            
            if isCharInAnyCar(PLAYER_PED) then
                local veh = storeCarCharIsInNoSave(PLAYER_PED)
                if getDriverOfCar(veh) == PLAYER_PED then
                    if veh ~= lastVehicle then
                        lastVehicle = veh
                        lua_thread.create(function()
                            if mainIni.toggles.autosport then
                                isAutomatingSport = true
                                wait(400)
                                if isCharInAnyCar(PLAYER_PED) then
                                    scriptKeyAction = true
                                    ae.send("onArizonaSendKey", { key = 82, _unknown = 0 })
                                    scriptKeyAction = false
                                    wait(1000)
                                end
                                isAutomatingSport = false
                            end
                            
                            if mainIni.toggles.autodrift then
                                if mainIni.toggles.autosport then wait(300) end
                                isAutomatingDrift = true
                                wait(400)
                                if isCharInAnyCar(PLAYER_PED) then
                                    scriptKeyAction = true
                                    ae.send("onArizonaSendKey", { key = 82, _unknown = 0 })
                                    scriptKeyAction = false
                                    wait(1000)
                                end
                                isAutomatingDrift = false
                            end
                        end)
                    end
                end
            else
                lastVehicle = -1
                isAutomatingSport = false
                isAutomatingDrift = false
            end
        end
    end
end

function triggerBodyCamera()
    if not mainIni.toggles.bodycam then return end
    lua_thread.create(function()
        wait(2500) 
        sampSendChat("/bodycamera")
    end)
end

function sampev.onSendSpawn() triggerBodyCamera() end
function sampev.onSetPlayerPos()
    if isWaitingForSpawn then
        isWaitingForSpawn = false
        triggerBodyCamera()
    end
end
function sampev.onSendDeathNotification() isWaitingForSpawn = true end

function sampev.onSendDialogResponse(id, but, lis, input)
    if captcha_dialog_id and id == captcha_dialog_id then
        local time_taken = os.clock() - real_captcha_start
        local time_formatted = string.format("%.3f", time_taken)
        sampAddChatMessage(string.format("{FFFFFF}Введенная капча: {22A872}[%s]{FFFFFF}, время ввода: {22A872}[%s сек]{FFFFFF}", input, time_formatted), -1)
        captcha_dialog_id = nil
    end
end

function onReceivePacket(id, bs)
    if not mainIni.toggles.balloon then return end
    if id == 220 then
        local readOffset = raknetBitStreamGetReadOffset(bs)
        raknetBitStreamIgnoreBits(bs, 8)
        local hasId = raknetBitStreamReadInt8(bs)
        
        if hasId == 17 then
            raknetBitStreamIgnoreBits(bs, 32)
            local len = raknetBitStreamReadInt16(bs)
            
            if len > 0 and len < 32000 then
                local enc = raknetBitStreamReadInt8(bs)
                local command = (enc ~= 0) and raknetBitStreamDecodeString(bs, len + enc) or raknetBitStreamReadString(bs, len)
                local event_name, event_data = string.match(command, "^window%.executeEvent%('(.-)', [`'](%b[])[`']%);$")
                if event_name == "event.setActiveView" then
                    clickerState = false
                    local data = decodeJson(event_data)
                    if type(data) == "table" then
                        for _, veiw in ipairs(data) do
                            if veiw == "Clicker" then clickerState = true break end
                        end
                    end
                end
            end
        end
        raknetBitStreamSetReadOffset(bs, readOffset)
    end
end