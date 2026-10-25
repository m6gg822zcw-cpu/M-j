#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project without third-party build generators."""
from pathlib import Path
import hashlib
import json
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
PROJ = ROOT / "Moxu.xcodeproj"
PROJ.mkdir(exist_ok=True)
objects = []
def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value), ensure_ascii=False)
def obj(key, value): objects.append(f"\t\t{uid(key)} = {{ {value} }};")
def ids(keys): return "(" + ", ".join(uid(k) for k in keys) + (", )" if keys else ")")
sources = sorted((ROOT / "App").glob("*.swift"))
ui_sources = sorted((ROOT / "UITests").glob("*.swift"))
resources = [("Assets.xcassets","folder.assetcatalog"),("PrivacyInfo.xcprivacy","text.xml"),("Resources/LetteringDemo.moxu","archive.zip")]
children = []
for path in sources:
    ref, build = "ref:"+path.name, "src:"+path.name
    obj(ref, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path.name)}; sourceTree = "<group>";')
    obj(build, f'isa = PBXBuildFile; fileRef = {uid(ref)};')
    children.append(ref)
for name, typ in resources:
    ref, build = "ref:"+name, "resource:"+name
    obj(ref, f'isa = PBXFileReference; lastKnownFileType = {typ}; path = {q(name)}; sourceTree = "<group>";')
    obj(build, f'isa = PBXBuildFile; fileRef = {uid(ref)};')
    children.append(ref)
obj("ref:Info.plist", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
children.append("ref:Info.plist")
obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Moxu.app; sourceTree = BUILT_PRODUCTS_DIR;')
ui_children = []
for path in ui_sources:
    ref, build = "ui-ref:"+path.name, "ui-src:"+path.name
    obj(ref, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path.name)}; sourceTree = "<group>";')
    obj(build, f'isa = PBXBuildFile; fileRef = {uid(ref)};')
    ui_children.append(ref)
obj("ui-product", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = MoxuUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj("core-package", 'isa = XCLocalSwiftPackageReference; relativePath = Packages/MoxuCore;')
obj("core-product", f'isa = XCSwiftPackageProductDependency; package = {uid("core-package")}; productName = MoxuCore;')
obj("core-link", f'isa = PBXBuildFile; productRef = {uid("core-product")};')
obj("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {ids(["src:"+p.name for p in sources])}; runOnlyForDeploymentPostprocessing = 0;')
obj("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {ids(["resource:"+n for n,t in resources])}; runOnlyForDeploymentPostprocessing = 0;')
obj("frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {ids(["core-link"])}; runOnlyForDeploymentPostprocessing = 0;')
obj("app-group", f'isa = PBXGroup; children = {ids(children)}; path = App; sourceTree = "<group>";')
obj("ui-sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {ids(["ui-src:"+p.name for p in ui_sources])}; runOnlyForDeploymentPostprocessing = 0;')
obj("ui-frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj("ui-resources", 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj("ui-group", f'isa = PBXGroup; children = {ids(ui_children)}; path = UITests; sourceTree = "<group>";')
obj("products-group", f'isa = PBXGroup; children = {ids(["product","ui-product"])}; name = Products; sourceTree = "<group>";')
obj("main-group", f'isa = PBXGroup; children = {ids(["app-group","ui-group","products-group"])}; sourceTree = "<group>";')
obj("ui-app-proxy", f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = Moxu;')
obj("ui-app-dependency", f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {uid("ui-app-proxy")};')
for config in ["Debug","Release"]:
    project_settings = {
        "CLANG_ENABLE_MODULES":"YES","CLANG_ENABLE_OBJC_ARC":"YES",
        "SDKROOT":"iphoneos","IPHONEOS_DEPLOYMENT_TARGET":"17.0",
        "SWIFT_VERSION":"5.0","ENABLE_USER_SCRIPT_SANDBOXING":"YES",
        "GCC_C_LANGUAGE_STANDARD":"gnu17","CLANG_CXX_LANGUAGE_STANDARD":"gnu++20",
        "SWIFT_OPTIMIZATION_LEVEL":"-Onone" if config=="Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT":"dwarf" if config=="Debug" else "dwarf-with-dsym",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS":"DEBUG $(inherited)" if config=="Debug" else "$(inherited)",
        "SWIFT_COMPILATION_MODE":"singlefile" if config=="Debug" else "wholemodule",
        "ENABLE_TESTABILITY":"YES" if config=="Debug" else "NO",
    }
    target_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME":"AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME":"AccentColor",
        "CODE_SIGN_STYLE":"Automatic","CURRENT_PROJECT_VERSION":"6",
        "DEVELOPMENT_TEAM":"","GENERATE_INFOPLIST_FILE":"NO",
        "INFOPLIST_FILE":"App/Info.plist","MARKETING_VERSION":"1.1.3",
        "PRODUCT_BUNDLE_IDENTIFIER":"com.yourname.moxu","PRODUCT_NAME":"$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator","SUPPORTS_MACCATALYST":"NO",
        "TARGETED_DEVICE_FAMILY":"1,2","SWIFT_EMIT_LOC_STRINGS":"YES",
        "ENABLE_PREVIEWS":"YES",
        "LD_RUNPATH_SEARCH_PATHS":"$(inherited) @executable_path/Frameworks",
    }
    ui_settings = {
        "CODE_SIGNING_ALLOWED":"NO", "CODE_SIGNING_REQUIRED":"NO",
        "GENERATE_INFOPLIST_FILE":"YES", "IPHONEOS_DEPLOYMENT_TARGET":"17.0",
        "PRODUCT_BUNDLE_IDENTIFIER":"com.yourname.moxu.uitests", "PRODUCT_NAME":"$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS":"iphonesimulator", "SUPPORTS_MACCATALYST":"NO",
        "TARGETED_DEVICE_FAMILY":"1,2", "TEST_TARGET_NAME":"Moxu",
        "LD_RUNPATH_SEARCH_PATHS":"$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
    }
    for name,settings in [("project",project_settings),("target",target_settings),("ui-target",ui_settings)]:
        serialized=" ".join(f"{k} = {q(v)};" for k,v in settings.items())
        obj(name+"-"+config,f'isa = XCBuildConfiguration; buildSettings = {{ {serialized} }}; name = {config};')
for name in ["project","target","ui-target"]:
    obj(name+"-configs", f'isa = XCConfigurationList; buildConfigurations = {ids([name+"-Debug",name+"-Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj("target",f'isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")}; buildPhases = {ids(["sources","frameworks","resources"])}; buildRules = (); dependencies = (); name = Moxu; packageProductDependencies = {ids(["core-product"])}; productName = Moxu; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
obj("ui-target",f'isa = PBXNativeTarget; buildConfigurationList = {uid("ui-target-configs")}; buildPhases = {ids(["ui-sources","ui-frameworks","ui-resources"])}; buildRules = (); dependencies = {ids(["ui-app-dependency"])}; name = MoxuUITests; productName = MoxuUITests; productReference = {uid("ui-product")}; productType = "com.apple.product-type.bundle.ui-testing";')
obj("project",f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {uid("target")} = {{ CreatedOnToolsVersion = 16.0; }}; {uid("ui-target")} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {uid("target")}; }}; }}; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 15.0"; developmentRegion = "zh-Hans"; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base, ); mainGroup = {uid("main-group")}; packageReferences = {ids(["core-package"])}; productRefGroup = {uid("products-group")}; projectDirPath = ""; projectRoot = ""; targets = {ids(["target","ui-target"])};')
(PROJ/"project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 60;\n\tobjects = {\n"+"\n".join(objects)+"\n\t};\n\trootObject = "+uid("project")+";\n}\n")
scheme_dir=PROJ/"xcshareddata"/"xcschemes";scheme_dir.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="Moxu.app" BlueprintName="Moxu" ReferencedContainer="container:Moxu.xcodeproj"/>'
ui_ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("ui-target")}" BuildableName="MoxuUITests.xctest" BlueprintName="MoxuUITests" ReferencedContainer="container:Moxu.xcodeproj"/>'
(scheme_dir/"Moxu.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{ui_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{ui_ref}</TestableReference></Testables><MacroExpansion>{ref}</MacroExpansion></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
workspace=PROJ/"project.xcworkspace";workspace.mkdir(exist_ok=True)
(workspace/"contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')
print(f"Generated {PROJ.name}: {len(sources)} native Swift files + local MoxuCore package + {len(ui_sources)} UI test files")
