#!/usr/bin/env python3
"""Offline alignment fixture. Creates a precise test chart, not AI artwork."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from zipfile import ZipFile, ZIP_DEFLATED
from io import BytesIO
import json, uuid

ROOT=Path(__file__).resolve().parents[1]
out=ROOT/"App"/"Resources"/"LetteringDemo.moxu"
out.parent.mkdir(parents=True,exist_ok=True)
image=Image.new("RGB",(1024,1536),"#f9f4e9")
draw=ImageDraw.Draw(image)
font_paths=[
    Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
    Path("/System/Library/Fonts/PingFang.ttc"),
    Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
]
font_path=next((p for p in font_paths if p.exists()),None)
font=ImageFont.truetype(str(font_path),28) if font_path else ImageFont.load_default()
for i in range(1,10):
    x=round(1024*i/10);y=round(1536*i/10)
    draw.line((x,0,x,1536),fill="#e2ddd2",width=2)
    draw.line((0,y,1024,y),fill="#e2ddd2",width=2)
    draw.text((8,y+5),f"{i*10}%",fill="#8b8277",font=font)
draw.rounded_rectangle((200,730,350,1170),radius=35,fill="#90b7b0")
draw.rounded_rectangle((675,730,825,1170),radius=35,fill="#d9aaa0")
for x,color,label in [(266,"#90b7b0","A"),(758,"#d9aaa0","B")]:
    draw.ellipse((x-86,535,x+86,707),fill=color)
    draw.line((x-15,645,x+15,645),fill="#25423f",width=5)
    draw.line((x,632,x,658),fill="#25423f",width=5)
    draw.text((x-9,800),label,fill="#25423f",font=font)
draw.text((75,1380),"OFFLINE LETTERING / ALIGNMENT TEST",fill="#52665f",font=font)
png=BytesIO();image.save(png,format="PNG")
pid=str(uuid.uuid4()).upper()
ids=[str(uuid.uuid4()).upper() for _ in range(2)]
date="2026-10-24T00:00:00Z"
source="左侧A说：气泡可以移动。右侧B说：尾尖可以单独调整。"
costume={"key":"test","name":"离线示意","layers":{k:"示意区域" for k in ["base","top","bottom","outer","footwear","accessories"]},
         "naiLayers":{k:"none" for k in ["base","top","bottom","outer","footwear","accessories"]},"naiTags":""}
characters=[{"id":cid,"lineageID":cid,"name":name,"stage":"离线示意","aliases":[],
             "identity":{"species":"纸娃娃示意","face":"十字定位标记"},"naiIdentity":"test chart, paper doll",
             "designNotes":"用于验收气泡排版，不是AI生成漫画。","evidence":[],"costumes":[costume],"revision":1}
            for cid,name in zip(ids,["左侧A","右侧B"])]
cast=[{"characterID":cid,"costumeKey":"test","pose":"站立示意","expression":"无","position":pos,
       "visible":"示意轮廓","props":"","injuries":"","naiPose":"standing","layerStates":{}}
      for cid,pos in zip(ids,["画面左侧","画面右侧"])]
panel={"id":"P0001","units":["U00001"],"scene":"S1","setting":"离线坐标示意图","time":"测试",
       "shot":"全景","camera":"平视","lighting":"均匀","action":"仅用于检查气泡拖动、尾尖和导出位置。",
       "naiScene":"2people, test chart","cast":cast,
       "dialogue":[{"speaker":"左侧A","text":"拖动白色气泡，调整我的位置。","kind":"speech"},
                   {"speaker":"右侧B","text":"橙点调整尾尖，青色角点调整大小。","kind":"speech"}],
       "narration":"离线排版示例，不会调用任何API。","sfx":"","imageFile":"Images/chart.png",
       "fingerprint":"","lastPrompt":"","requestJSON":"{}","reviewNotes":"离线定位图，不是生成结果。",
       "review":"pending"}
unit={"id":"U00001","text":source,"utf16Start":0}
run={"ordinal":1,"title":"气泡编辑验收","units":[unit],"batches":[["U00001"]],"doneBatches":1,
     "panels":[panel],"summary":source,"memoryBefore":"","memoryAfter":"离线验收。",
     "continuity":{"scene":"S1","time":"测试","notes":"离线示意。","castStates":{}},"planned":True}
project={"id":pid,"title":"气泡排版 · 离线示例","chapters":[{"ordinal":1,"title":"气泡编辑验收",
         "characterCount":len(source),"completedPanels":1,"totalPanels":1,"planned":True}],
         "characters":characters,"conflicts":[],"relations":[],"created":date,"updated":date}
def encode(value):return json.dumps(value,ensure_ascii=False,indent=2).encode()
with ZipFile(out,"w",ZIP_DEFLATED) as z:
    z.writestr("Project.json",encode(project))
    z.writestr("Chapters/1-source.json",encode([unit]))
    z.writestr("Chapters/1-run.json",encode(run))
    z.writestr("Images/chart.png",png.getvalue())
print(f"Created {out.relative_to(ROOT)} ({out.stat().st_size} bytes)")
