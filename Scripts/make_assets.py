#!/usr/bin/env python3
"""Create the app's geometric icon and Apple metadata (Pillow only for icon)."""
from pathlib import Path
import json
import plistlib
from PIL import Image, ImageDraw

ROOT=Path(__file__).resolve().parents[1]
ASSETS=ROOT/"App"/"Assets.xcassets"
ASSETS.mkdir(parents=True,exist_ok=True)
def js(path,value):path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n")
js(ASSETS/"Contents.json",{"info":{"author":"xcode","version":1}})
icon=ASSETS/"AppIcon.appiconset";icon.mkdir(exist_ok=True)
scale=2
im=Image.new("RGB",(1024*scale,1024*scale),"#183c3d")
d=ImageDraw.Draw(im)
def rect(box,fill,rad=0,width=0,outline=None):
    box=tuple(int(v*scale) for v in box)
    if rad:d.rounded_rectangle(box,radius=int(rad*scale),fill=fill,outline=outline,width=int(width*scale))
    else:d.rectangle(box,fill=fill,outline=outline,width=int(width*scale))
def line(points,fill,width):d.line([(int(x*scale),int(y*scale))for x,y in points],fill=fill,width=int(width*scale),joint="curve")
paper="#f7f0e1";ink="#183c3d";coral="#cb775d"
rect((177,177,847,847),paper,rad=42)
line([(482,211),(482,808)],"#dfd5c1",6)
rect((220,226,439,532),ink,rad=8)
d.ellipse((264*scale,267*scale,345*scale,348*scale),fill=coral)
line([(228,484),(310,388),(374,451),(433,388)],paper,14)
rect((220,569,439,798),ink,rad=8)
line([(253,619),(401,619)],paper,12)
line([(253,655),(377,655)],paper,12)
line([(253,691),(389,691)],paper,12)
rect((524,226,804,464),ink,rad=8)
line([(556,410),(635,335),(701,392),(771,315)],paper,14)
rect((524,503,804,798),ink,rad=8)
line([(570,699),(641,594),(702,653),(750,579)],paper,16)
rect((711,725,888,901),coral,rad=88)
d.polygon([(794*scale,756*scale),(840*scale,803*scale),(796*scale,861*scale),(758*scale,822*scale)],fill=paper)
line([(795,814),(785,837)],ink,7)
im.resize((1024,1024),Image.Resampling.LANCZOS).save(icon/"AppIcon.png")
js(icon/"Contents.json",{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}})
for name,values in {"AccentColor":(0.76,0.35,0.27),"LaunchBackground":(0.97,0.95,0.91)}.items():
    folder=ASSETS/(name+".colorset");folder.mkdir(exist_ok=True)
    colors=[{"idiom":"universal","color":{"color-space":"srgb","components":{"red":str(values[0]),"green":str(values[1]),"blue":str(values[2]),"alpha":"1.000"}}}]
    if name=="LaunchBackground":colors.append({"idiom":"universal","appearances":[{"appearance":"luminosity","value":"dark"}],"color":{"color-space":"srgb","components":{"red":"0.07","green":"0.08","blue":"0.09","alpha":"1.000"}}})
    js(folder/"Contents.json",{"colors":colors,"info":{"author":"xcode","version":1}})
info={
 "CFBundleDevelopmentRegion":"zh-Hans","CFBundleDisplayName":"墨序",
 "CFBundleExecutable":"$(EXECUTABLE_NAME)","CFBundleIdentifier":"$(PRODUCT_BUNDLE_IDENTIFIER)",
 "CFBundleInfoDictionaryVersion":"6.0","CFBundleName":"$(PRODUCT_NAME)","CFBundlePackageType":"APPL",
 "CFBundleShortVersionString":"$(MARKETING_VERSION)","CFBundleVersion":"$(CURRENT_PROJECT_VERSION)",
 "LSRequiresIPhoneOS":True,"LSSupportsOpeningDocumentsInPlace":True,
 "UIApplicationSupportsIndirectInputEvents":True,
 "UILaunchScreen":{"UIColorName":"LaunchBackground"},
 "UISupportedInterfaceOrientations":["UIInterfaceOrientationPortrait","UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"],
 "UISupportedInterfaceOrientations~ipad":["UIInterfaceOrientationPortrait","UIInterfaceOrientationPortraitUpsideDown","UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"],
 "NSAppTransportSecurity":{"NSAllowsArbitraryLoads":True},
 "NSLocalNetworkUsageDescription":"连接你自行配置的局域网文本或生图服务。",

}
info.update(json.loads((ROOT/"Scripts"/"document_types.json").read_text()))
(ROOT/"App"/"Info.plist").write_bytes(plistlib.dumps(info,sort_keys=False))
privacy={"NSPrivacyTracking":False,"NSPrivacyTrackingDomains":[],"NSPrivacyCollectedDataTypes":[],"NSPrivacyAccessedAPITypes":[
 {"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryUserDefaults","NSPrivacyAccessedAPITypeReasons":["CA92.1"]},
 {"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryFileTimestamp","NSPrivacyAccessedAPITypeReasons":["C617.1","3B52.1"]},
]}
(ROOT/"App"/"PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy,sort_keys=False))
print("Wrote app icon, asset colors, Info.plist and privacy manifest.")
