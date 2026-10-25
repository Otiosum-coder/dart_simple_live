
import os, math
from PIL import Image, ImageDraw, ImageFont
F="C:/Windows/Fonts/msyh.ttc"; FB="C:/Windows/Fonts/msyhbd.ttc"
OUT=r"E:\Project\simple_live\dart_simple_live\docs\mockups"
BG=(16,17,22); PANEL=(27,28,35); PANEL2=(38,40,50); FG=(233,235,242); SUB=(148,154,168); ACC=(76,141,255)
def ft(s,b=False): return ImageFont.truetype(FB if b else F,s)
def txt(d,xy,s,sz=13,b=False,fill=FG,anchor="la"): d.text(xy,s,font=ft(sz,b),fill=fill,anchor=anchor)
def tw(d,s,sz=13,b=False): return d.textlength(s,font=ft(sz,b))
def heart_pts(cx,cy,size):
    pts=[]
    for i in range(120):
        t=2*math.pi*i/120
        x=16*math.sin(t)**3
        y=13*math.cos(t)-5*math.cos(2*t)-2*math.cos(3*t)-math.cos(4*t)
        pts.append((cx+x*size/17, cy-y*size/17))
    return pts
def heart(d,cx,cy,size,fill=None,outline=None,w=2):
    pts=heart_pts(cx,cy,size)
    if fill: d.polygon(pts,fill=fill)
    if outline: d.line(pts+[pts[0]],fill=outline,width=w,joint="curve")
W=640; rowh=104; H=30+rowh*3+16
cv=Image.new("RGB",(W,H),BG); d=ImageDraw.Draw(cv)
txt(d,(16,8),"竖屏「关注」按钮的 3 种方案（开启发送弹幕后，位于主播名右侧）",13,True)
def profile(y):
    d.rectangle((0,y,W,y+rowh),fill=PANEL)
    d.ellipse((16,y+24,64,y+72),fill=(72,92,124))
    txt(d,(80,y+20),"14德莱文",16,True)
    txt(d,(80,y+50),"斗鱼直播",11,False,SUB)
    return 80+tw(d,"14德莱文",16,True)+16
def cap(y,s): txt(d,(16,y+rowh-16),s,10,False,(255,150,150))
def pill(x,y,w,h,label,fill,fg,outline=None):
    d.rounded_rectangle((x,y,x+w,y+h),radius=h//2,fill=fill,outline=outline)
    txt(d,(x+w/2,y+h/2+1),label,13,True,fg,"mm")
# A
y=30; x=profile(y)
pill(x,y+34,88,32,"关注",ACC,(255,255,255))
pill(x+100,y+34,88,32,"已关注",None,(170,176,188),(90,94,106))
txt(d,(x+200,y+42),"（左：未关注 / 右：已关注）",10,False,SUB)
cap(y,"A  填充胶囊：关注=主题色实心；已关注=灰色描边")
# B
y=30+rowh; x=profile(y)
heart(d,x+12,y+56,11,None,(255,120,150),2); txt(d,(x+30,y+44),"关注",14,False,(255,140,170))
heart(d,x+92,y+56,11,(255,120,150)); txt(d,(x+110,y+44),"已关注",14,False,SUB)
cap(y,"B  图标+文字（无底色，最轻量）：空心心=未关注，实心=已关注")
# C
y=30+rowh*2; x=profile(y)
d.ellipse((x,y+32,x+40,y+72),fill=ACC); heart(d,x+20,y+54,10,None,(255,255,255),2)
d.ellipse((x+56,y+32,x+96,y+72),fill=PANEL2); heart(d,x+76,y+54,10,(170,176,188))
txt(d,(x+110,y+42),"（左：未关注 / 右：已关注）",10,False,SUB)
cap(y,"C  圆形图标按钮（最省空间，适合窄屏 / 长主播名）")
cv.save(os.path.join(OUT,"4-follow-options.png")); print("OK")
