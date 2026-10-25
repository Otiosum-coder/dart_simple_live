
import os, math
from PIL import Image, ImageDraw, ImageFont
F="C:/Windows/Fonts/msyh.ttc"; FB="C:/Windows/Fonts/msyhbd.ttc"
OUT=r"E:\Project\simple_live\dart_simple_live\docs\mockups"
BG=(16,17,22); PANEL=(27,28,35); FG=(233,235,242); SUB=(148,154,168); ACC=(76,141,255); ORG=(255,160,72)
def ft(s,b=False): return ImageFont.truetype(FB if b else F,s)
def txt(d,xy,s,sz=13,b=False,fill=FG,anchor="la"): d.text(xy,s,font=ft(sz,b),fill=fill,anchor=anchor)
def tw(d,s,sz=13,b=False): return d.textlength(s,font=ft(sz,b))
def heartpts(cx,cy,size):
    return [(cx+(16*math.sin(2*math.pi*i/90)**3)*size/17, cy-(13*math.cos(2*math.pi*i/90)-5*math.cos(4*math.pi*i/90)-2*math.cos(6*math.pi*i/90)-math.cos(8*math.pi*i/90))*size/17) for i in range(90)]
def heart(d,cx,cy,size,fill=None,outline=None,w=2):
    p=heartpts(cx,cy,size)
    if fill: d.polygon(p,fill=fill)
    if outline: d.line(p+[p[0]],fill=outline,width=w,joint="curve")
def circ(d,cx,cy,r,label=None,color=ACC):
    d.ellipse((cx-r,cy-r,cx+r,cy+r),fill=color)
    heart(d,cx,cy,r*0.55,None,(255,255,255),2)
W=560; rh=104; H=30+rh*4+10
cv=Image.new("RGB",(W,H),BG); d=ImageDraw.Draw(cv)
txt(d,(16,8),"竖屏「关注」按钮位置 4 种方案（红框=当前突兀位置）",13,True)
def row(y,label,draw):
    d.rectangle((0,y,W,y+rh),fill=PANEL)
    d.ellipse((16,y+22,60,y+66),fill=(72,92,124))
    txt(d,(74,y+18),"Drop辛巴",15,True)
    txt(d,(74,y+42),"斗鱼直播",11,False,SUB)
    txt(d,(W-16,y+24),"热度 119.7万",12,False,ORG,"ra")
    draw(y)
    txt(d,(16,y+rh-16),label,10,False,(255,150,150))
# A 热度下方（第二行右侧）
row(30,"A  热度下方：与热度同列第二行（右对齐，和热度上下排列）",lambda y: circ(d,W-60,y+64,16))
# B 头像右下角小徽章
def b(y):
    d.ellipse((44,y+50,64,y+70),fill=ACC); heart(d,54,y+60,7,None,(255,255,255),1)
row(30+rh,"B  头像右下角小徽章（最省空间，不占主播名/热度位置）",b)
# C 主播名下方第二行（与平台标签同排）
def c(y):
    txt(d,(74,y+62),"斗鱼直播",11,False,SUB); circ(d,74+tw(d,"斗鱼直播",11)+30,y+66,14)
row(30+rh*2,"C  主播名下方第二行：跟在「斗鱼直播」标签后面",c)
# D 圆角胶囊文字（放在热度左边）
def dd(y):
    w=64; x=W-16-tw(d,"热度 119.7万",12,False)-12-w
    d.rounded_rectangle((x,y+44,x+w,y+76),radius=16,fill=ACC)
    txt(d,(x+w/2,y+60),"关注",12,True,(255,255,255),"mm")
row(30+rh*3,"D  热度左侧放胶囊文字「关注」（状态更清晰，占一点横向空间）",dd)
cv.save(os.path.join(OUT,"5-follow-position.png")); print("OK")
