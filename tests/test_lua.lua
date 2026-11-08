-- SPDX-License-Identifier: MIT
local ffi=require("ffi")
local function stub(name,value) package.preload[name]=function() return value or {} end end
stub("ffi/blitbuffer",{})
stub("device",{screen={}})
for _,name in ipairs({"ui/font","ui/geometry","ui/gesturerange","ui/widget/infomessage","ui/widget/textwidget","ui/widget/textviewer","ui/uimanager"}) do stub(name,{}) end
stub("ui/widget/container/inputcontainer",{extend=function(_,v)return v end})
stub("socket",{gettime=os.clock})
local module=dofile("lua/appdock_android.lua")
local RFB=module._test.RFB
local p16,p32=module._test.p16,module._test.p32
local count=0
local function check(v,message) count=count+1; assert(v,message) end
local function client(chunks)
    local sock={sent={},chunks=chunks or {}}
    function sock:settimeout()end
    function sock:send(data)self.sent[#self.sent+1]=data;return #data end
    function sock:receive()local c=table.remove(self.chunks,1);return nil,"timeout",c or "" end
    local r=RFB.attach(sock,2,2)
    return r,r.fb,sock
end
local red=string.char(0x00,0xF8) -- RGB565 little endian: 0xF800
local update="\0\0"..p16(1)..p16(0)..p16(0)..p16(2)..p16(2)..p32(0)..red:rep(4)
local r,fb,sock=client({update:sub(1,7),update:sub(8,19),update:sub(20)})
check(not r:poll(),"partial header must not draw")
check(not r:poll(),"partial pixels must not draw")
check(r:poll(),"full fragmented pixels must draw")
check(fb[0]==0xF800 and fb[3]==0xF800,"RGB565 pixels copied into the local framebuffer")
local dx0,dy0,dx1,dy1=r:take_dirty()
check(dx0==0 and dy0==0 and dx1==2 and dy1==2,"dirty rectangle covers the update")
check(r:take_dirty()==nil,"dirty rectangle is consumed")
check(#sock.sent==1 and sock.sent[1]:byte(1)==3,"request next incremental frame")
-- Teil-Rechteck (x=1,y=1,1x1) darf nur sein eigenes Pixel veraendern.
local green=string.char(0xE0,0x07)
local part,pfb=client({"\0\0"..p16(1)..p16(1)..p16(1)..p16(1)..p16(1)..p32(0)..green})
check(part:poll(),"partial rectangle must draw")
check(pfb[3]==0x07E0 and pfb[0]==0xFFFF and pfb[1]==0xFFFF and pfb[2]==0xFFFF,"only the target pixel changes")
local d0,e0,d1,e1=part:take_dirty()
check(d0==1 and e0==1 and d1==2 and e1==2,"dirty rectangle of a partial update")
-- Zwei Updates in einem Socket-Lesevorgang werden beide verarbeitet.
local two,tfb=client({update..("\0\0"..p16(1)..p16(0)..p16(0)..p16(1)..p16(1)..p32(0)..green)})
check(two:poll(),"back-to-back updates in one read")
check(tfb[0]==0x07E0 and tfb[1]==0xF800,"second update applied after the first")
local empty,_,es=client({"\0\0\0\0"})
check(not empty:poll(),"empty update is not a repaint")
check(#es.sent==1,"empty update cannot stall the stream")
local bad=client({"\0\0"..p16(1)..p16(1)..p16(0)..p16(2)..p16(2)..p32(0)})
check(not pcall(bad.poll,bad),"out-of-bounds rectangle rejected")
local encoding=client({"\0\0"..p16(1)..p16(0)..p16(0)..p16(2)..p16(2)..p32(5)})
check(not pcall(encoding.poll,encoding),"non-raw encoding rejected")
local clip=client({"\3\0\0\0"..p32(999999)})
check(not pcall(clip.poll,clip),"oversized clipboard rejected")
local ptr,_,ps=client()
ptr:pointer(-10,99,true)
check(ps.sent[1]=="\5\1\0\0\0\1","pointer clamped")
check(module._test.quote("a'b")=="'a'\\''b'","shell argument escaped")
-- Touch-Ende: jede Geste, die eine Beruehrung beendet, muss den Zeiger loslassen (sonst BTN_TOUCH haengt).
local pa=module._test.pointer_action
check(pa("touch",false,true)=="down" and pa("touch",false,false)==nil,"touch presses only inside Android view")
check(pa("pan",true,false)=="move" and pa("pan",false,false)==nil,"pan continues an active press")
for _,k in ipairs({"release","pan_release","tap","hold_release","swipe","double_tap"}) do
    check(pa(k,true,true)=="up","gesture "..k.." releases an active press")
end
check(pa("tap",false,true)=="tap" and pa("tap",false,false)==nil,"tap without prior touch is synthesized only inside")
check(pa("hold",true,true)==nil,"hold keeps the press")
-- Dither-Tabelle muss exakt das alte pixelweise Verfahren ergeben (gleiche Schwellen).
local bit=require("bit")
local lut=module._test.build_lut()
local TH={32,160,224,96}
for _,p in ipairs({0,0xFFFF,0xF800,0x07E0,0x001F,0x8410,0x4208,0xC618,0x1234,0xABCD}) do
    local r5,g6,b5=bit.rshift(p,11),bit.band(bit.rshift(p,5),63),bit.band(p,31)
    local r,g,b=bit.bor(bit.lshift(r5,3),bit.rshift(r5,2)),bit.bor(bit.lshift(g6,2),bit.rshift(g6,4)),bit.bor(bit.lshift(b5,3),bit.rshift(b5,2))
    for k=0,3 do
        local t=TH[k+1]
        local want=0xff000000+(r>=t and 0xff or 0)+(g>=t and 0xff00 or 0)+(b>=t and 0xff0000 or 0)
        check(lut[k*65536+p]==want,"dither LUT matches reference for "..p.." phase "..k)
    end
end
-- Teil-Rendering == Voll-Rendering (Skalierung 5x6 -> 13x17, nicht ganzzahlig).
local W,H,DW,DH=5,6,13,17
local src=ffi.new("uint16_t[?]",W*H)
for i=0,W*H-1 do src[i]=(i*2741+97)%65536 end
local xm,ym=ffi.new("uint16_t[?]",DW),ffi.new("uint16_t[?]",DH)
for dx=0,DW-1 do xm[dx]=math.min(W-1,math.floor(dx*W/DW)) end
for dy=0,DH-1 do ym[dy]=math.min(H-1,math.floor(dy*H/DH)) end
local full=ffi.new("uint32_t[?]",DW*DH)
module._test.render_region(src,W,H,full,DW,xm,ym,DW,DH,0,0,W,H,lut)
local inc=ffi.new("uint32_t[?]",DW*DH)
for _,rc in ipairs({{0,0,W,3},{0,3,W,H}}) do
    module._test.render_region(src,W,H,inc,DW,xm,ym,DW,DH,rc[1],rc[2],rc[3],rc[4],lut)
end
local same=true
for i=0,DW*DH-1 do if full[i]~=inc[i] then same=false end end
check(same,"region-wise rendering equals full rendering")
-- Referenz: alter Pixel-fuer-Pixel-Weg.
for dy=0,DH-1 do for dx=0,DW-1 do
    local p=src[ym[dy]*W+xm[dx]]
    local r5,g6,b5=bit.rshift(p,11),bit.band(bit.rshift(p,5),63),bit.band(p,31)
    local r,g,b=bit.bor(bit.lshift(r5,3),bit.rshift(r5,2)),bit.bor(bit.lshift(g6,2),bit.rshift(g6,4)),bit.bor(bit.lshift(b5,3),bit.rshift(b5,2))
    local t=TH[(dy%2)*2+(dx%2)+1]
    local want=0xff000000+(r>=t and 0xff or 0)+(g>=t and 0xff00 or 0)+(b>=t and 0xff0000 or 0)
    assert(full[dy*DW+dx]==want,"pixel "..dx..","..dy)
end end
count=count+1
print("Lua RFB: "..count.." assertions passed")
