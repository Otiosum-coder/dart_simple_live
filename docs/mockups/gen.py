
import os
from PIL import Image, ImageDraw, ImageFont

F  = "C:/Windows/Fonts/msyh.ttc"
FB = "C:/Windows/Fonts/msyhbd.ttc"
OUT = r"E:\Project\simple_live\dart_simple_live\docs\mockups"
os.makedirs(OUT, exist_ok=True)

BG=(16,17,22); PANEL=(27,28,35); PANEL2=(38,40,50); VIDEO=(9,9,12)
FG=(233,235,242); SUB=(148,154,168); ACC=(76,141,255); RED=(255,72,72)
WARN=(255,168,72); DIM=(96,101,116)

def ft(s,b=False): return ImageFont.truetype(FB if b else F, s)
def txt(d,xy,s,sz=13,b=False,fill=FG,anchor="la"):
    d.text(xy,s,font=ft(sz,b),fill=fill,anchor=anchor)
def tw(d,s,sz=13,b=False): return d.textlength(s,font=ft(sz,b))
def rr(d,box,r=8,fill=PANEL,outline=None,w=1):
    d.rounded_rectangle(box,radius=r,fill=fill,outline=outline,width=w)
def pill(d,box,label,sz=13,fill=ACC,fg=(255,255,255)):
    d.rounded_rectangle(box,radius=(box[3]-box[1])//2,fill=fill)
    txt(d,((box[0]+box[2])/2,(box[1]+box[3])/2+1),label,sz,True,fg,"mm")
def redbox(d,box):
    d.rounded_rectangle(box,radius=10,outline=RED,width=3)

def wrap(d, s, maxw, sz, b=False):
    lines=[]; cur=""
    for ch in s:
        if tw(d,cur+ch,sz,b) > maxw:
            lines.append(cur); cur=ch
        else:
            cur+=ch
    if cur: lines.append(cur)
    return lines

def base(w,h,label,note):
    nh=26+ (18 if tw(ImageDraw.Draw(Image.new("RGB",(10,10))),note,11)<=w-32 else 34) + 46
    cv=Image.new("RGB",(w,h+nh),BG); d=ImageDraw.Draw(cv)
    txt(d,(16,8),label,15,True,(255,255,255))
    right="开启发送弹幕后的布局 · 关闭时保持原 UI"
    if tw(d,right,11)+tw(d,label,15,True)+60 <= w:
        txt(d,(w-16,10),right,11,False,SUB,"ra")
    y=h+26+6
    for ln in wrap(d,note,w-32,11):
        txt(d,(16,y),ln,11,False,(255,150,150)); y+=18
    return cv,d,26

def icons_row(d, x, y, items, sz=12, gap=10, h=26):
    for label in items:
        w=tw(d,label,sz)+18
        rr(d,(x,y,x+w,y+h),7,PANEL)
        txt(d,(x+w/2,y+h/2+1),label,sz,False,FG,"mm")
        x+=w+gap
    return x

# ---------------- 竖屏 ----------------
WP,HP=390,844
cv,d,Y=base(WP,HP,"竖屏（移动端）","▲ 红框：输入框常驻在聊天列表下方（一行 56px，仅「聊天」tab 显示）。关注按钮在主播名右侧；刷新/分享收进右上角菜单")
d.rectangle((0,Y,WP,Y+HP),fill=BG)
txt(d,(14,Y+8),"21:35",11,True,SUB); txt(d,(330,Y+8),"5G  82%",10,False,SUB)
txt(d,(14,Y+34),"←",18,False,FG); txt(d,(60,Y+38),"我在重庆支持369",14,True); txt(d,(344,Y+38),"···",17,False,FG)
vy=Y+64; d.rectangle((0,vy,WP,vy+219),fill=VIDEO)
txt(d,(195,vy+62),"视频画面 16:9",13,False,DIM,"mm")
txt(d,(12,vy+8),"人机局",12,False,(240,220,120)); txt(d,(238,vy+34),"说明你打不过人机",12,False,(120,200,255)); txt(d,(58,vy+150),"徒步",12,False,(255,255,255))
iy=vy+219
d.rectangle((0,iy,WP,iy+64),fill=PANEL)
d.ellipse((16,iy+14,52,iy+50),fill=(72,92,124))
txt(d,(62,iy+12),"14德莱文",15,True); txt(d,(62,iy+34),"斗鱼直播",11,False,SUB)
pill(d,(146,iy+18,208,iy+46),"关注",12,(58,60,72),(215,220,230))
txt(d,(WP-14,iy+22),"热度 84.9万",12,True,WARN,"ra")
ty=iy+64; d.rectangle((0,ty,WP,ty+44),fill=PANEL)
txt(d,(65,ty+20),"聊天",14,True,FG,"mm"); d.rectangle((46,ty+40,84,ty+42),fill=ACC)
txt(d,(195,ty+20),"关注",14,False,SUB,"mm"); txt(d,(325,ty+20),"设置",14,False,SUB,"mm")
msgs=[("系统","正在读取直播间信息",SUB),("网友1顺4德莱文","人机局",FG),("Drop白神","说明你打不过人机",FG),("他娘的意大利面","徒步",FG),("钯碧玺","很难想象这种FPS天赋几乎为零",FG),("系统","弹幕服务器连接正常",SUB)]
cy=ty+56
for n,t,c in msgs:
    txt(d,(14,cy),n+"：",12,True,(150,170,200)); x=14+tw(d,n+"：",12,True); txt(d,(x,cy),t,12,False,c); cy+=32
by=Y+HP-56; d.rectangle((0,by,WP,Y+HP),fill=PANEL)
rr(d,(10,by+9,300,by+47),22,PANEL2); txt(d,(24,by+28),"说点什么吧~",13,False,SUB,"lm")
pill(d,(310,by+9,380,by+47),"发送",14)
redbox(d,(6,by+5,384,by+51))
cv.save(os.path.join(OUT,"1-portrait.png"))

# ---------------- 横屏 ----------------
WL,HL=844,390
cv,d,Y=base(WL,HL,"横屏 / 全屏（移动端）","▲ 红框：输入框嵌在底部控制条中部；点一下画面唤出控制条时显示，随控制条一起淡出。键盘弹出时整体上移")
d.rectangle((0,Y,WL,Y+HL),fill=VIDEO)
txt(d,(40,Y+40),"人机局",14,False,(240,220,120)); txt(d,(600,Y+70),"说明你打不过人机",14,False,(120,200,255)); txt(d,(300,Y+130),"徒步",14,False,(255,255,255))
cb=Y+HL-58
d.rectangle((0,cb,WL,Y+HL),fill=(18,18,24))
d.line((0,cb,WL,cb),fill=(52,54,66),width=1)
x=icons_row(d,18,cb+16,["刷新","弹幕","设置"],12,10,26)
txt(d,(x+6,cb+22),"04:04:35",12,False,SUB)
rr(d,(250,cb+12,532,cb+50),19,PANEL2); txt(d,(266,cb+31),"说点什么吧~",13,False,SUB,"lm")
pill(d,(540,cb+12,608,cb+50),"发送",14)
redbox(d,(246,cb+8,616,cb+54))
txt(d,(WL-16,cb+22),"原画1080P60   线路1   全屏",12,False,SUB,"ra")
cv.save(os.path.join(OUT,"2-landscape.png"))

# ---------------- 桌面 ----------------
WD,HD=1280,720
cv,d,Y=base(WD,HD,"桌面端（Windows 窗口）","▲ 输入框在右侧面板最底部（原按钮位置）；分享 / 复制链接 / 复制播放直链 三个按钮左移到底栏左侧，与刷新 / 取消关注同一行")
d.rectangle((0,Y,WD,Y+HD),fill=BG)
pw=360; px=WD-pw; bh=60
d.rectangle((0,Y,px,Y+HD-bh),fill=VIDEO)
txt(d,(px/2,Y+(HD-bh)/2),"视频画面（自适应）",15,False,DIM,"mm")
d.rectangle((px,Y,WD,Y+HD-bh),fill=PANEL)
d.ellipse((px+18,Y+16,px+58,Y+56),fill=(72,92,124))
txt(d,(px+70,Y+16),"14德莱文",15,True); txt(d,(px+70,Y+38),"哔哩哔哩",11,False,SUB)
pill(d,(px+180,Y+20,px+246,Y+50),"关注",12,(58,60,72),(215,220,230))
txt(d,(WD-14,Y+24),"热度 1.1万",12,True,WARN,"ra")
ty=Y+70; d.rectangle((px,ty,WD,ty+44),fill=PANEL2)
txt(d,(px+62,ty+20),"聊天",14,True,FG,"mm"); d.rectangle((px+44,ty+40,px+82,ty+42),fill=ACC)
txt(d,(px+186,ty+20),"关注",14,False,SUB,"mm"); txt(d,(px+306,ty+20),"设置",14,False,SUB,"mm")
msgs=[("系统","正在读取直播间信息",SUB),("五十铃花","现在套现是利润最小的时候",FG),("西伯利亚狂奔","现在天天问你，为啥你消费呢？",FG),("系统","弹幕服务器连接正常",SUB),("网友A","这个画面有点糊",FG),("网友B","线路1挺稳的",FG)]
cy=ty+62
for n,t,c in msgs:
    txt(d,(px+16,cy),n+"：",12,True,(150,170,200)); x=px+16+tw(d,n+"：",12,True); txt(d,(x,cy),t,12,False,c); cy+=34
bb=Y+HD-bh; d.rectangle((0,bb,WD,Y+HD),fill=PANEL2)
x=icons_row(d,16,bb+17,["刷新","取消关注","分享","复制链接","复制播放直链"],12,10,26)
redbox(d,(10,bb+11,x-4,bb+49))
inp=(px+14,bb+12,WD-104,bb+48); rr(d,inp,18,PANEL2)
txt(d,(inp[0]+14,bb+30),"说点什么吧~",13,False,SUB,"lm")
pill(d,(WD-96,bb+12,WD-14,bb+48),"发送",14)
redbox(d,(inp[0]-8,bb+6,WD-6,bb+54))
cv.save(os.path.join(OUT,"3-desktop.png"))
print("OK")