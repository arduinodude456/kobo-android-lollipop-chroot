-- SPDX-License-Identifier: MIT
-- Android KitKat through a loopback-only RFB 3.8 connection. No external viewer.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local socket = require("socket")
local Screen = Device.screen
local BASE = os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android"
local HOST, PORT = "127.0.0.1", 5963
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function exists(path) local f = io.open(path, "rb"); if f then f:close(); return true end; return false end
local function command(arg) return "sh " .. quote(BASE .. "/android.sh") .. " " .. arg end
local function tail_file(path, limit)
    local f = io.open(path, "rb")
    if not f then return "" end
    local n = f:seek("end") or 0; f:seek("set", math.max(0, n - limit))
    local s = f:read("*a") or ""; f:close(); return s
end
local function run_cmd(cmd, limit)
    local f = io.popen(cmd .. " 2>&1")
    if not f then return "" end
    local out = f:read("*a") or ""; f:close()
    if #out > limit then out = out:sub(-limit) end
    return out
end
local function diagnostics()
    local kmsg = tail_file(BASE .. "/run/rootfs/dev/kmsg", 2400)
    local log = tail_file(BASE .. "/android.log", 3200)
    local init = tail_file(BASE .. "/android-init.log", 1200)
    if log == "" then log = "Kein android.log vorhanden." end
    if init ~= "" then log = log .. "\n\n--- android-init.log ---\n" .. init end
    if kmsg ~= "" then log = "--- init/kmsg (live) ---\n" .. kmsg .. "\n\n--- android.log ---\n" .. log end
    -- Android-init schreibt per klog in den HOST-Kernel-Log (dmesg), nicht in die Datei dev/kmsg.
    local dm = run_cmd("dmesg | grep -iE 'init:|binder|ashmem|surfaceflinger|zygote|servicemanager|healthd|avc' | tail -n 60", 3000)
    local ps = run_cmd("ps | grep -iE '/init|zygote|surfaceflinger|servicemanager|system_server|kobo-vnc' | grep -v grep", 1500)
    -- Written by the binder shim inside libkobofb.so (KOBO_BINDER_LOG): proves LD_PRELOAD reached the
    -- Android processes and lists translation errors.
    local shim = tail_file(BASE .. "/run/rootfs/data/local/tmp/kobo-binder.log", 1500)
    local watch = tail_file(BASE .. "/bootwatch.log", 1500)
    if watch ~= "" then log = "--- Boot-Zeitachse ---\n" .. watch .. "\n\n" .. log end
    local lc = tail_file(BASE .. "/logcat.txt", 2500)
    local tb = tail_file(BASE .. "/tombstone.txt", 1500)
    if tb ~= "" then log = "--- tombstone ---\n" .. tb .. "\n\n" .. log end
    log = "--- logcat ---\n" .. (lc ~= "" and lc or "(leer: android.log ohne Eintraege)") .. "\n\n" .. log
    local hd = tail_file(BASE .. "/healthd.txt", 1500)
    if hd ~= "" then log = "--- healthd ---\n" .. hd .. "\n\n" .. log end
    local egl = tail_file(BASE .. "/egl.txt", 2000)
    if egl ~= "" then log = "--- egl ---\n" .. egl .. "\n\n" .. log end
    log = "--- binder shim ---\n" .. (shim ~= "" and shim or "(leer: Shim wurde in keinem Prozess geladen)") .. "\n\n" .. log
    log = "--- Prozesse ---\n" .. (ps ~= "" and ps or "(keine Android-Prozesse)") ..
          "\n\n--- dmesg (init/Android) ---\n" .. (dm ~= "" and dm or "(leer)") .. "\n\n" .. log
    return log
end
local function recover_stale_state()
    -- recover is conservative: active Android processes are never killed.
    os.execute("(" .. command("recover") .. ") >/dev/null 2>&1")
end
local function u16(s, i) local a,b=s:byte(i,i+1); return a*256+b end
local function u32(s, i) local a,b,c,d=s:byte(i,i+3); return ((a*256+b)*256+c)*256+d end
local function p16(v) return string.char(math.floor(v/256)%256, v%256) end
local function p32(v) return p16(math.floor(v/65536)%65536)..p16(v%65536) end
local RFB = {}; RFB.__index = RFB
-- 1-Bit-Dithering je Farbkanal (2x2-Bayer, Schwellen wie bisher). Statt pro Pixel drei
-- Vergleiche in Lua auszufuehren, gibt es je Phase (dx%2, dy%2) eine Tabelle
-- RGB565 -> fertiges RGB32-Pixel (acht erlaubte Farben). Pro Ausgabepixel bleibt ein
-- einziger Tabellenzugriff.
local bit=require("bit")
local DITHER_THRESHOLDS={32,160,224,96}
local lut_cache
local function build_lut()
    if lut_cache then return lut_cache end
    local lut=ffi.new("uint32_t[?]",4*65536)
    for p=0,65535 do
        local r5=bit.rshift(p,11); local g6=bit.band(bit.rshift(p,5),63); local b5=bit.band(p,31)
        local r=bit.bor(bit.lshift(r5,3),bit.rshift(r5,2))
        local g=bit.bor(bit.lshift(g6,2),bit.rshift(g6,4))
        local b=bit.bor(bit.lshift(b5,3),bit.rshift(b5,2))
        for k=0,3 do
            local t=DITHER_THRESHOLDS[k+1]
            local v=0xff000000
            if r>=t then v=v+0xff end
            if g>=t then v=v+0xff00 end
            if b>=t then v=v+0xff0000 end
            lut[k*65536+p]=v
        end
    end
    lut_cache=lut; return lut
end
-- Zeichnet nur den geaenderten Quellbereich [sx0,sx1)x[sy0,sy1) skaliert (nearest) und
-- gedithert in den Canvas. Liefert den betroffenen Zielbereich (exklusive Obergrenze).
local function render_region(fb16,w,h,canvas,cstride4,xmap,ymap,draw_w,draw_h,sx0,sy0,sx1,sy1,lut)
    local dx0=math.max(0,math.ceil(sx0*draw_w/w)); local dx1=math.min(draw_w,math.ceil(sx1*draw_w/w))
    local dy0=math.max(0,math.ceil(sy0*draw_h/h)); local dy1=math.min(draw_h,math.ceil(sy1*draw_h/h))
    if dx1<=dx0 or dy1<=dy0 then return nil end
    local band=bit.band
    for dy=dy0,dy1-1 do
        local srow=fb16+ymap[dy]*w
        local drow=canvas+dy*cstride4
        local rowk=band(dy,1)*131072
        for dx=dx0,dx1-1 do
            drow[dx]=lut[rowk+band(dx,1)*65536+srow[xmap[dx]]]
        end
    end
    return dx0,dy0,dx1,dy1
end
function RFB:send(s)
    -- Only tiny control packets. A blocked/closed local peer is an error, not a UI hang.
    self.sock:settimeout(0.2)
    local n, err = self.sock:send(s)
    self.sock:settimeout(0)
    if n ~= #s then error("RFB senden: " .. tostring(err)) end
end
function RFB:read(n)
    local data, err = self.sock:receive(n)
    if not data then error("RFB Handshake: " .. tostring(err)) end
    return data
end
-- Verbindungsobjekt mit festem Empfangspuffer (ffi) und lokalem RGB565-Abbild des
-- Android-Bildschirms. Kein String-Anhaengen/Abschneiden mehr: das kostete bei einem
-- 1-MB-Frame quadratisch viel Kopierarbeit.
function RFB.attach(sock, w, h)
    local self = setmetatable({sock=sock, w=w, h=h, rects=nil}, RFB)
    self.cap = w*h*2 + 65536
    self.rx = ffi.new("uint8_t[?]", self.cap); self.pos, self.len = 0, 0
    self.fb = ffi.new("uint16_t[?]", w*h)
    self.fb8 = ffi.cast("uint8_t*", self.fb)
    ffi.fill(self.fb, w*h*2, 0xff)
    return self
end
function RFB.connect()
    local s = assert(socket.tcp())
    s:settimeout(0.35)
    local ok, err = s:connect(HOST, PORT)
    if not ok then s:close(); return nil, err end
    local hs = setmetatable({sock=s}, RFB)
    local result
    local success, why = pcall(function()
        s:settimeout(1)
        assert(hs:read(12) == "RFB 003.008\n", "RFB-Version wird nicht unterstützt")
        assert(s:send("RFB 003.008\n"))
        local n = hs:read(1):byte(); assert(n > 0 and n <= 16, "RFB Security")
        local types = hs:read(n); assert(types:find("\1", 1, true), "Nur lokales RFB ohne Auth wird unterstützt")
        assert(s:send("\1")); assert(u32(hs:read(4),1)==0, "RFB verweigert")
        assert(s:send("\1"))
        local init = hs:read(24)
        local w, h = u16(init,1), u16(init,3)
        assert(w >= 1 and w <= 1024 and h >= 1 and h <= 1024, "Ungültige Bildgröße")
        assert(w*h <= 786432, "Bild ist zu groß")
        local namelen=u32(init,21); assert(namelen<=1024,"Desktopname zu lang"); hs:read(namelen)
        -- RGB565 little endian = Format des Android-Framebuffers: der Server kopiert nur noch
        -- Speicher (halbe Datenmenge, keine Umrechnung); der Client dithert per Tabelle.
        assert(s:send("\0\0\0\0" .. string.char(16,16,0,1) .. p16(31)..p16(63)..p16(31)..string.char(11,5,0).."\0\0\0"))
        assert(s:send("\2\0"..p16(1)..p32(0)))
        result = RFB.attach(s, w, h)
        s:settimeout(0)
        result:request(false)
    end)
    if not success then if result then result:close() else s:close() end; return nil, why end
    return result
end
function RFB:close()
    if self.sock then self.sock:close(); self.sock=nil end
    self.fb=nil; self.fb8=nil; self.rx=nil
end
function RFB:request(incremental)
    self:send("\3"..string.char(incremental and 1 or 0)..p16(0)..p16(0)..p16(self.w)..p16(self.h))
end
function RFB:key(sym, down) self:send("\4"..string.char(down and 1 or 0).."\0\0"..p32(sym)) end
function RFB:pointer(x,y,down)
    x=math.max(0,math.min(self.w-1,math.floor(x))); y=math.max(0,math.min(self.h-1,math.floor(y)))
    self:send("\5"..string.char(down and 1 or 0)..p16(x)..p16(y))
end
function RFB:consume(n)
    self.pos=self.pos+n
    if self.pos>=self.len then self.pos,self.len=0,0 end
end
-- Den Socket in einem Tick komplett leeren (bis der Puffer voll ist). Frueher waren es
-- hoechstens 4x32 KB pro 50 ms = 2,5 MB/s, also unter einem Vollbild pro Sekunde.
function RFB:fill()
    for _=1,16 do
        local room=self.cap-self.len
        if room<=0 and self.pos>0 then
            ffi.copy(self.rx,self.rx+self.pos,self.len-self.pos)
            self.len=self.len-self.pos; self.pos=0; room=self.cap-self.len
        end
        if room<=0 then break end
        local data,err,part=self.sock:receive(math.min(room,262144))
        data=data or part
        local n=data and #data or 0
        if n>0 then ffi.copy(self.rx+self.len,data,n); self.len=self.len+n end
        if err=="closed" then error("Android-Verbindung beendet") end
        if err=="timeout" or n==0 then break end
    end
end
function RFB:mark(x0,y0,x1,y1)
    if self.dx0 then
        if x0<self.dx0 then self.dx0=x0 end; if y0<self.dy0 then self.dy0=y0 end
        if x1>self.dx1 then self.dx1=x1 end; if y1>self.dy1 then self.dy1=y1 end
    else self.dx0,self.dy0,self.dx1,self.dy1=x0,y0,x1,y1 end
end
function RFB:take_dirty()
    local x0,y0,x1,y1=self.dx0,self.dy0,self.dx1,self.dy1
    self.dx0,self.dy0,self.dx1,self.dy1=nil,nil,nil,nil
    return x0,y0,x1,y1
end
function RFB:poll()
    -- No blocking receive on the KOReader UI thread. Bound both memory and work.
    self:fill()
    local changed=false
    for _=1,64 do
        local avail=self.len-self.pos
        local rx,pos=self.rx,self.pos
        if self.pixel_rect then
            local r=self.pixel_rect; local need=r.w*r.h*2
            if avail<need then break end
            local src=rx+pos
            if r.x==0 and r.w==self.w then
                ffi.copy(self.fb8+r.y*self.w*2,src,need)
            else
                for row=0,r.h-1 do ffi.copy(self.fb8+((r.y+row)*self.w+r.x)*2,src+row*r.w*2,r.w*2) end
            end
            self:consume(need); self:mark(r.x,r.y,r.x+r.w,r.y+r.h)
            self.pixel_rect=nil; self.rects=self.rects-1; changed=true
        elseif self.rects and self.rects>0 then
            if avail<12 then break end
            local x,y=rx[pos]*256+rx[pos+1],rx[pos+2]*256+rx[pos+3]
            local w,h=rx[pos+4]*256+rx[pos+5],rx[pos+6]*256+rx[pos+7]
            local enc=((rx[pos+8]*256+rx[pos+9])*256+rx[pos+10])*256+rx[pos+11]
            assert(enc==0,"Unbekanntes RFB-Encoding")
            assert(w>0 and h>0 and x+w<=self.w and y+h<=self.h,"Ungültiges RFB-Rechteck")
            self:consume(12); self.pixel_rect={x=x,y=y,w=w,h=h}
        elseif self.rects==0 then
            self.rects=nil; self:request(true)
        else
            if avail<1 then break end
            local t=rx[pos]
            if t==0 then
                if avail<4 then break end
                self.rects=rx[pos+2]*256+rx[pos+3]; assert(self.rects<=64,"Zu viele RFB-Rechtecke")
                self:consume(4)
            elseif t==2 then self:consume(1)
            elseif t==3 then
                if avail<8 then break end
                local n=((rx[pos+4]*256+rx[pos+5])*256+rx[pos+6])*256+rx[pos+7]
                assert(n<=4096,"Zwischenablage zu groß")
                if avail<8+n then break end; self:consume(8+n)
            else error("Unbekannte RFB-Nachricht") end
        end
    end
    return changed
end
-- KOReader liefert fuer das Ende einer Beruehrung je nach Geste "tap", "swipe", "hold_release",
-- "pan_release" oder "double_tap" (eine rohe Geste "release" gibt es nicht zuverlaessig). Wer nur auf
-- "release"/"pan_release" lauscht, laesst BTN_TOUCH in Android fuer immer gedrueckt: Touch wirkt tot.
local END_GESTURES={release=true,pan_release=true,tap=true,hold_release=true,swipe=true,double_tap=true}
local function pointer_action(kind,pointer_down,inside)
    if kind=="touch" then return inside and "down" or nil
    elseif kind=="pan" then return (inside or pointer_down) and "move" or nil
    elseif END_GESTURES[kind] then
        if pointer_down then return "up" end
        if kind=="tap" and inside then return "tap" end
    end
    return nil
end
local View=InputContainer:extend{name="KoboAndroid",covers_fullscreen=true}
function View:init()
    self.dimen=Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}
    self.ges_events={}
    for _,g in ipairs({"touch","release","tap","pan","pan_release","hold","hold_release","swipe","double_tap"}) do
        self.ges_events[g]={GestureRange:new{ges=g,range=self.dimen},event="AndroidGesture"}
    end
    self.key_events={AndroidBack={{"Back"},event="AndroidBack"}}
    self.face=Font:getFace("cfont",22)
    self.status=TextWidget:new{text="Android startet. Der erste Boot kann mehrere Minuten dauern.",face=self.face,max_width=self.dimen.w-40}
    self.buttons={}
    local defs={{"Zurück",0xff1b},{"Home",0xff50},{"Menü",0xffbe},{"Log","log"},{"Beenden",false}}
    local bw=math.floor(self.dimen.w/#defs)
    for i,d in ipairs(defs) do
        self.buttons[i]={label=TextWidget:new{text=d[1],face=self.face},key=d[2],rect=Geom:new{x=(i-1)*bw,y=self.dimen.h-90,w=bw,h=90}}
    end
    -- WLAN fuer Android: Der Kobo verbindet, Android spiegelt den Zustand (docs/WLAN.md).
    pcall(function()
        local NM=require("ui/network/manager")
        if NM.isWifiOn and not NM:isWifiOn() and NM.turnOnWifi then NM:turnOnWifi() end
    end)
    recover_stale_state()
    os.execute(command("start") .. " >/dev/null 2>&1")
    self.deadline=socket.gettime()+180
    self.tick=function() self:pollAndroid() end
    UIManager:scheduleIn(0.5,self.tick)
end
function View:paintTo(bb,x,y)
    if self.rfb and self.canvas then
        -- Das Android-Bild liegt fertig skaliert und gedithert im Canvas (wird nur fuer die
        -- geaenderten Pixel in pollAndroid() aktualisiert). Hier bleibt je Zeile ein memcpy.
        local dw,dh=self.draw_w,self.draw_h
        local same=true
        if type(bb.getType)=="function" and Blitbuffer.TYPE_BBRGB32 then
            same=(bb:getType()==Blitbuffer.TYPE_BBRGB32)
        end
        if same then
            local dst_stride=tonumber(bb.stride) or self.dimen.w*4
            local dst_base=ffi.cast("uint8_t*",bb.data)
            local src_base=ffi.cast("const uint8_t*",self.canvas)
            local rowbytes=dw*4
            for dy=0,dh-1 do
                ffi.copy(dst_base+(y+self.oy+dy)*dst_stride+(x+self.ox)*4,src_base+dy*rowbytes,rowbytes)
            end
        elseif self.canvas_bb then
            bb:blitFrom(self.canvas_bb,x+self.ox,y+self.oy,0,0,dw,dh)
        end
    else
        bb:paintRect(x,y,self.dimen.w,self.dimen.h,Blitbuffer.COLOR_WHITE)
        self.status:paintTo(bb,x+20,y+40)
    end
    for _,b in ipairs(self.buttons) do
        local r=b.rect; bb:paintRect(x+r.x,y+r.y,r.w-2,r.h,Blitbuffer.COLOR_BLACK)
        bb:paintRect(x+r.x+2,y+r.y+2,r.w-6,r.h-4,Blitbuffer.COLOR_WHITE)
        local sz=b.label:getSize(); b.label:paintTo(bb,x+r.x+math.floor((r.w-sz.w)/2),y+r.y+30)
    end
end
function View:fail(text)
    UIManager:close(self,"full")
    UIManager:show(InfoMessage:new{text=text .. "\n\n" .. diagnostics()})
end
function View:setupCanvas(rfb)
    self.draw_w=self.dimen.w
    self.draw_h=self.dimen.h-90
    self.ox=0; self.oy=0
    local dw,dh=self.draw_w,self.draw_h
    self.xmap=ffi.new("uint16_t[?]",dw); self.ymap=ffi.new("uint16_t[?]",dh)
    for dx=0,dw-1 do self.xmap[dx]=math.min(rfb.w-1,math.floor(dx*rfb.w/dw)) end
    for dy=0,dh-1 do self.ymap[dy]=math.min(rfb.h-1,math.floor(dy*rfb.h/dh)) end
    self.canvas=ffi.new("uint32_t[?]",dw*dh)
    ffi.fill(self.canvas,dw*dh*4,0xff)
    if Blitbuffer.new and Blitbuffer.TYPE_BBRGB32 then
        local ok,cbb=pcall(Blitbuffer.new,dw,dh,Blitbuffer.TYPE_BBRGB32,self.canvas,dw*4)
        if ok then self.canvas_bb=cbb end
    end
    self.lut=build_lut()
end
function View:pollAndroid()
    if self.closed then return end
    -- Adaptiver Takt: kurz nach einem Bildwechsel oder einer Eingabe schnell pollen, im Leerlauf
    -- (stehendes E-Ink-Bild) nur noch etwa 8x pro Sekunde. Der feste 30-ms-Takt weckte KOReader 33x/s
    -- und stahl dem Single-Core-Gespann Android+KOReader CPU.
    local delay=0.12
    local t0=socket.gettime()
    if t0 < (self.active_until or 0) then delay=0.03 end
    if not self.rfb then
        local rfb=RFB.connect()
        if rfb then
            self.rfb=rfb
            self:setupCanvas(rfb)
            self.next_full_refresh=socket.gettime()+30
            UIManager:setDirty(self,"full")
        elseif socket.gettime()>self.deadline then self:fail("Android konnte nicht gestartet werden."); return end
    else
        local ok,changed=pcall(self.rfb.poll,self.rfb)
        if not ok then self:fail(tostring(changed)); return end
        local region
        if changed then
            local sx0,sy0,sx1,sy1=self.rfb:take_dirty()
            if sx0 then
                local dx0,dy0,dx1,dy1=render_region(self.rfb.fb,self.rfb.w,self.rfb.h,self.canvas,self.draw_w,
                    self.xmap,self.ymap,self.draw_w,self.draw_h,sx0,sy0,sx1,sy1,self.lut)
                if dx0 then region=Geom:new{x=self.ox+dx0,y=self.oy+dy0,w=dx1-dx0,h=dy1-dy0} end
            end
            delay=0.01
            self.active_until=socket.gettime()+1.0
        end
        local now=socket.gettime()
        if now >= (self.next_full_refresh or now+30) then
            self.next_full_refresh=now+30
            UIManager:setDirty(self,"full")
        elseif region then
            -- Nur der geaenderte Ausschnitt wird am E-Ink aufgefrischt: kleinere Flaeche =
            -- deutlich kuerzere Panel-Updatezeit.
            UIManager:setDirty(self,"fast",region)
        end
    end
    UIManager:scheduleIn(delay,self.tick)
end
function View:boost(seconds)
    local now=socket.gettime()
    local was_idle = now >= (self.active_until or 0)
    self.active_until=now+(seconds or 1.5)
    -- Der naechste Leerlauf-Tick kann bis zu 120 ms entfernt sein: bei Eingabe sofort vorziehen.
    if was_idle and self.tick and self.rfb and not self.closed then
        UIManager:unschedule(self.tick)
        UIManager:scheduleIn(0.01,self.tick)
    end
end
function View:pulse(key)
    if not self.rfb then return end
    self:boost(2)
    local r=self.rfb; local ok,err=pcall(r.key,r,key,true)
    if not ok then self:fail(tostring(err)); return end
    local cb
    cb=function()
        self.key_timers[cb]=nil
        if not self.closed and self.rfb==r then pcall(r.key,r,key,false) end
    end
    self.key_timers=self.key_timers or {}; self.key_timers[cb]=true; UIManager:scheduleIn(0.12,cb)
end
function View:showLog()
    UIManager:show(TextViewer:new{title="Android-Log",text=diagnostics(),width=self.dimen.w,height=self.dimen.h})
end
-- Sicherheitsnetz: geht jedes Ende-Ereignis verloren, wird die Beruehrung nach 6 s trotzdem geloest.
function View:disarmWatchdog()
    if self.watchdog then UIManager:unschedule(self.watchdog); self.watchdog=nil end
end
function View:armWatchdog()
    self:disarmWatchdog()
    self.watchdog=function()
        self.watchdog=nil
        if self.pointer_down and not self.closed and self.rfb then
            self.pointer_down=false
            pcall(self.rfb.pointer,self.rfb,self.px or 0,self.py or 0,false)
        end
    end
    UIManager:scheduleIn(6,self.watchdog)
end
function View:onAndroidBack() self:pulse(0xff1b); return true end
function View:onAndroidGesture(_,ges)
    if self.closed then return true end
    local pos=ges.pos
    if not pos then return true end
    self:boost(1.5)
    local kind=ges.ges
    if kind=="tap" then
        for _,b in ipairs(self.buttons) do
            if b.rect:contains(pos) then
                if b.key=="log" then self:showLog()
                elseif b.key then self:pulse(b.key) else UIManager:close(self,"full") end
                return true
            end
        end
    end
    if not self.rfb then return true end
    local sx,sy=pos.x-self.ox,pos.y-self.oy
    local inside=sx>=0 and sy>=0 and sx<self.draw_w and sy<self.draw_h
    -- Die sichtbare, skalierte Position wird in die native Android-Auflösung
    -- zurückgerechnet, damit Touch trotz Vollbilddarstellung korrekt bleibt.
    local x,y=sx*self.rfb.w/self.draw_w,sy*self.rfb.h/self.draw_h
    local now=socket.gettime()
    local function pointer(down,px,py)
        local ok,err=pcall(self.rfb.pointer,self.rfb,px,py,down)
        if not ok then self:fail(tostring(err)) end
    end
    local action=pointer_action(kind,self.pointer_down,inside)
    if action=="down" or action=="move" then
        self.pointer_down=true; self.px,self.py=x,y; pointer(true,x,y); self:armWatchdog()
    elseif action=="up" then
        self.pointer_down=false; self:disarmWatchdog()
        pointer(false,self.px or x,self.py or y)
    elseif action=="tap" then
        -- Beruehrung ohne vorheriges "touch" (z.B. verlorenes Ereignis): Tipp nachbilden.
        pointer(true,x,y)
        self.tap_release=function()
            if not self.closed and self.rfb then pcall(self.rfb.pointer,self.rfb,x,y,false) end
        end
        UIManager:scheduleIn(0.12,self.tap_release)
    end
    return true
end
function View:onCloseWidget()
    self.closed=true
    if self.tick then UIManager:unschedule(self.tick) end
    if self.tap_release then UIManager:unschedule(self.tap_release) end
    self:disarmWatchdog()
    for cb in pairs(self.key_timers or {}) do UIManager:unschedule(cb) end
    if self.rfb then self.rfb:close(); self.rfb=nil end
    -- Stop is deliberately asynchronous: no wait/sleep in the KOReader UI thread.
    os.execute("("..command("stop")..") >>"..quote(BASE.."/android.log").." 2>&1 &")
    if self.status then self.status:free() end
    for _,b in ipairs(self.buttons or {}) do b.label:free() end
    UIManager:setDirty(nil,"full")
end
local M={}
function M.available()
    if not exists(BASE.."/android.sh") or not exists(BASE.."/bin/kobo-vnc") then return false,"Android-Paket fehlt: "..BASE end
    return true
end
function M.open()
    local ok,err=M.available()
    if not ok then UIManager:show(InfoMessage:new{text=err}); return false end
    UIManager:show(View:new{}); return true
end
M._test={RFB=RFB,quote=quote,p16=p16,p32=p32,pointer_action=pointer_action,build_lut=build_lut,render_region=render_region}
return M
