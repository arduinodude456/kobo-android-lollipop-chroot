-- SPDX-License-Identifier: MIT
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local Android = InputContainer:extend{name="kobo_android",is_doc_only=false}
function Android:init() self.ui.menu:registerToMainMenu(self) end
local function base_dir() return os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android" end
local function read_file(path)
    local f = io.open(path, "rb"); if not f then return "(keine Datei: " .. path .. ")" end
    local s = f:read("*a") or ""; f:close(); return s
end
function Android:addToMainMenu(items)
    items.kobo_android_diag={text="Android-Diagnose (Stufentest)",sorting_hint="tools",callback=function()
        UIManager:show(InfoMessage:new{text="Stufentest laeuft (ca. 20-40 s) ...",timeout=2})
        UIManager:nextTick(function()
            os.execute("sh '"..base_dir().."/android.sh' stages >/dev/null 2>&1")
            local text = read_file(base_dir().."/stages.log")
            UIManager:show(TextViewer:new{title="Stufentest",text=text,width=require("device").screen:getWidth(),height=require("device").screen:getHeight()})
        end)
    end}
    items.kobo_android_gapps={text="Google-Apps (Core) installieren",sorting_hint="tools",callback=function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text="Google-Apps (Play Store, Play Services, Login, Setup-Assistent) in das Android-Image installieren?\n\nBenötigt /mnt/onboard/gapps-kern.zip und ca. 100 MB freien Platz im Image. Android muss beendet sein.",
            ok_text="Installieren",
            ok_callback=function()
                UIManager:show(InfoMessage:new{text="Installiere Google-Apps ...\nDas dauert einige Minuten.",timeout=2})
                UIManager:nextTick(function()
                    local f=io.popen("sh '"..base_dir().."/android.sh' gapps 2>&1")
                    local out=f and f:read("*a") or "(keine Ausgabe)"
                    if f then f:close() end
                    local dev=require("device")
                    UIManager:show(TextViewer:new{title="Google-Apps Installation",text=out,width=dev.screen:getWidth(),height=dev.screen:getHeight()})
                end)
            end,
        })
    end}
    local function run_android_cmd(arg,title,wait)
        UIManager:show(InfoMessage:new{text=wait,timeout=2})
        UIManager:nextTick(function()
            local f=io.popen("sh '"..base_dir().."/android.sh' "..arg.." 2>&1")
            local out=f and f:read("*a") or "(keine Ausgabe)"
            if f then f:close() end
            local dev=require("device")
            UIManager:show(TextViewer:new{title=title,text=out,width=dev.screen:getWidth(),height=dev.screen:getHeight()})
        end)
    end
    items.kobo_android_gapps_diag={text="Google-Apps prüfen (Diagnose)",sorting_hint="tools",callback=function()
        run_android_cmd("gapps-diag","Google-Apps Diagnose","Prüfe Google-Apps ...")
    end}
    items.kobo_android_reset={text="Android zurücksetzen (alle Daten löschen)",sorting_hint="tools",callback=function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text="ALLE Android-Daten löschen (Apps, Konten, Google-Apps, Einstellungen) und ein frisches Android-Image installieren?\n\nNicht rückgängig zu machen. Der Ordner android-shared bleibt erhalten. Android muss beendet sein.",
            ok_text="Alles löschen",
            ok_callback=function() run_android_cmd("reset","Android zurücksetzen","Setze Android zurück ...\nDas dauert einige Minuten.") end,
        })
    end}
    items.kobo_android_wipe={text="Android entfernen (Speicher freigeben)",sorting_hint="tools",callback=function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text="Das Android-Image mit ALLEN Daten löschen, um Speicher freizugeben? Android startet danach erst nach einer Neuinstallation (install.sh) wieder.\n\nNicht rückgängig zu machen.",
            ok_text="Entfernen",
            ok_callback=function() run_android_cmd("wipe","Android entfernen","Entferne Android-Image ...") end,
        })
    end}
    items.kobo_android={text="Android KitKat 4.4 (Chroot)",sorting_hint="tools",callback=function()
        local base=os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android"
        local ok,module=pcall(dofile,base.."/lua/appdock_android.lua")
        if not ok then UIManager:show(InfoMessage:new{text="Android-Modul konnte nicht geladen werden:\n"..tostring(module)}); return end
        module.open()
    end}
end
return Android
