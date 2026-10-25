
import os, math
from PIL import Image, ImageDraw, ImageFont
F="C:/Windows/Fonts/msyh.ttc"; FB="C:/Windows/Fonts/msyhbd.ttc"
OUT=r"E:\Project\simple_live\dart_simple_live\docs\mockups"
BG=(16,17,22); PANEL=(27,28,35); FG=(233,235,242); SUB=(148,154,168); ACC=(76,141,255); ORG=(255,160,72)
def ft(s,b=False): return ImageFont.truetype(FB if b else F,s)
def txt(d,xy,s,sz=13,b=False,fill=FG,anchor="la"): d.text(xy,s,font=ft(sz,b),fill=fill,anchor=anchor)
def tw(d,s,sz=13,b=False): return d.textlength(s,font=ft(sz,b))
def heat(d,x,y,size,label="119.7万"):
    d.ellipse((x,y,x+size,y+size),fill=ORG)
    txt(d,(x+size+6,y+size/2+1),label,12 if size<=18 else 14,False,ORG,"lm")
W=600; rh=112; H=30+rh*2+34
cv=Image.new("RGB",(W,H),BG); d=ImageDraw.Draw(cv)
txt(d,(16,8),"竖屏主播信息行：关注=方案A（热度下方，矩形按钮）＋ 热度缩小",13,True)
def row(y,label,btn_text,btn_fill,btn_fg,heat_size,heat_label):
    d.rectangle((0,y,W,y+rh),fill=PANEL)
    d.ellipse((16,y+26,62,y+72),fill=(72,92,124))
    txt(d,(76,y+22),"Drop辛巴",16,True)
    txt(d,(76,y+48),"斗鱼直播",11,False,SUB)
    # 热度（右上，缩小）
    hx=W-16-tw(d,heat_label,12,False)-heat_size-6
    heat(d,hx,y+22,heat_size,heat_label)
    # 矩形关注按钮：热度下方，右对齐
    bw=76; bh=30
    bx=W-16-bw; by=y+22+heat_size+8
    d.rounded_rectangle((bx,by,bx+bw,by+bh),radius=7,fill=btn_fill,outline=None if btn_fill else (90,94,106))
    txt(d,(bx+bw/2,by+bh/2+1),btn_text,12,True,btn_fg,"mm")
    txt(d,(16,y+rh-16),label,10,False,(255,150,150))
row(30,"A-1  未关注：主题色矩形「关注」／热度缩小到 16px 图标 + 12px 文字",
    "关注",ACC,(255,255,255),16,"119.7万")
row(30+rh,"A-2  已关注：灰色矩形「已关注」",
    "已关注",(58,60,70),(190,195,205),16,"119.7万")
txt(d,(16,30+rh*2+12),"对比：原热度为 20px 图标 + 14px 文字，与 16px 主播名同排显得抢眼；缩小后层级更清晰（主播名 > 热度 > 关注）",11,False,SUB)
cv.save(os.path.join(OUT,"6-follow-rect.png")); print("OK")
