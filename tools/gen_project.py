#!/usr/bin/env python3
"""生成 B9XController.xcodeproj（手写工程文件容易错，用脚本按文件列表生成）。

用法：python3 tools/gen_project.py
生成的 UUID 按路径确定性生成，重复运行结果一致。
"""
import hashlib
import os
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(ROOT, "B9XController")
PROJ_DIR = os.path.join(ROOT, "B9XController.xcodeproj")
SCHEME_DIR = os.path.join(PROJ_DIR, "xcshareddata", "xcschemes")

TARGET_NAME = "B9XController"
BUNDLE_ID = "com.enginecore.plus"
DEPLOYMENT_TARGET = "26.0"
MARKETING_VERSION = "0.8.143"
CURRENT_PROJECT_VERSION = "227"


def uid(key: str) -> str:
    """确定性 24 位大写十六进制 UUID。"""
    return uuid.uuid5(uuid.NAMESPACE_URL, "b9x-controller-ios:" + key).hex[:24].upper()


def collect_sources():
    sources = []
    for dirpath, _dirs, files in os.walk(APP_DIR):
        for f in sorted(files):
            if f.endswith(".swift"):
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, ROOT)
                sources.append(rel)
    return sorted(sources)


def collect_firmware():
    """固件镜像（B9XController/Firmware/*.bin），进 Resources 相位。"""
    firmware_dir = os.path.join(APP_DIR, "Firmware")
    if not os.path.isdir(firmware_dir):
        return []
    return sorted(
        os.path.join("B9XController", "Firmware", f)
        for f in os.listdir(firmware_dir)
        if f.endswith(".bin")
    )


def collect_uitest_sources():
    """UI 测试源码（B9XControllerUITests/*.swift），进 UITests target。"""
    uitest_dir = os.path.join(ROOT, "B9XControllerUITests")
    if not os.path.isdir(uitest_dir):
        return []
    return sorted(
        os.path.join("B9XControllerUITests", f)
        for f in os.listdir(uitest_dir)
        if f.endswith(".swift")
    )


def main():
    sources = collect_sources()
    assert sources, "no swift sources found"
    firmware = collect_firmware()
    uitest_sources = collect_uitest_sources()

    # ---- UUID 分配 ----
    ids = {}
    for s in sources:
        ids["buildfile:" + s] = uid("buildfile:" + s)
        ids["fileref:" + s] = uid("fileref:" + s)
    for s in uitest_sources:
        ids["uitest-buildfile:" + s] = uid("uitest-buildfile:" + s)
        ids["uitest-fileref:" + s] = uid("uitest-fileref:" + s)
    for f in firmware:
        ids["buildfile:" + f] = uid("buildfile:" + f)
        ids["fileref:" + f] = uid("fileref:" + f)
    extra_refs = {
        "Info.plist": "Info.plist",
        "Assets.xcassets": "Assets.xcassets",
        "LaunchScreen.storyboard": "LaunchScreen.storyboard",
        "CoreBluetooth.framework": "CoreBluetooth.framework",
        "AppIntents.framework": "AppIntents.framework",
        "product": "B9XController.app",
    }
    for key, name in extra_refs.items():
        ids["fileref:" + key] = uid("fileref:" + key)
    for key in ["Assets.xcassets", "LaunchScreen.storyboard", "CoreBluetooth.framework", "AppIntents.framework"]:
        ids["buildfile:" + key] = uid("buildfile:" + key)
    for key in ["sources-phase", "frameworks-phase", "resources-phase",
                "target", "project",
                "configlist-project", "configlist-target",
                "config-project-debug", "config-project-release",
                "config-target-debug", "config-target-release",
                "group-main", "group-app", "group-products",
                "group-Protocol", "group-Models", "group-BLE",
                "group-Controller", "group-UI", "group-Intents",
                "group-Firmware",
                "uitest-target", "uitest-sources-phase", "uitest-frameworks-phase",
                "uitest-configlist", "uitest-config-debug", "uitest-config-release",
                "uitest-dependency", "uitest-proxy", "group-uitests"]:
        ids[key] = uid(key)
    ids["fileref:uitest-product"] = uid("fileref:uitest-product")

    def ref(kind, key, comment=""):
        return ids[kind + ":" + key]

    # ---- 分组 ----
    groups = {
        "Protocol": [s for s in sources if "/Protocol/" in s],
        "Models": [s for s in sources if "/Models/" in s],
        "BLE": [s for s in sources if "/BLE/" in s],
        "Controller": [s for s in sources if "/Controller/" in s],
        "UI": [s for s in sources if "/UI/" in s],
        "Intents": [s for s in sources if "/Intents/" in s],
    }
    top_level = [s for s in sources if s.count("/") == 1]  # B9XController/*.swift

    objects = []

    def add(uuid_, comment, body):
        objects.append((uuid_, comment, body))

    # ---- PBXBuildFile ----
    for s in sources:
        name = os.path.basename(s)
        add(ids["buildfile:" + s], name + " in Sources",
            "{\n\t\t\tisa = PBXBuildFile;\n\t\t\tfileRef = %s /* %s */;\n\t\t}" % (ids["fileref:" + s], name))
    for s in uitest_sources:
        name = os.path.basename(s)
        add(ids["uitest-buildfile:" + s], name + " in Sources",
            "{\n\t\t\tisa = PBXBuildFile;\n\t\t\tfileRef = %s /* %s */;\n\t\t}" % (ids["uitest-fileref:" + s], name))
    add(ids["buildfile:Assets.xcassets"], "Assets.xcassets in Resources",
        "{\n\t\t\tisa = PBXBuildFile;\n\t\t\tfileRef = %s /* Assets.xcassets */;\n\t\t}" % ids["fileref:Assets.xcassets"])
    add(ids["buildfile:LaunchScreen.storyboard"], "LaunchScreen.storyboard in Resources",
        "{\n\t\t\tisa = PBXBuildFile;\n\t\t\tfileRef = %s /* LaunchScreen.storyboard */;\n\t\t}" % ids["fileref:LaunchScreen.storyboard"])
    for f in firmware:
        name = os.path.basename(f)
        add(ids["buildfile:" + f], name + " in Resources",
            "{\n\t\t\tisa = PBXBuildFile;\n\t\t\tfileRef = %s /* %s */;\n\t\t}" % (ids["fileref:" + f], name))
    for fw in ["CoreBluetooth.framework", "AppIntents.framework"]:
        add(ids["buildfile:" + fw], fw + " in Frameworks",
            "{\n\t\t\tisa = PBXBuildFile;\n\t\t\tfileRef = %s /* %s */;\n\t\t}" % (ids["fileref:" + fw], fw))

    # ---- PBXFileReference ----
    for s in sources:
        name = os.path.basename(s)
        add(ids["fileref:" + s], name,
            "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = sourcecode.swift;\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % name)
    for s in uitest_sources:
        name = os.path.basename(s)
        add(ids["uitest-fileref:" + s], name,
            "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = sourcecode.swift;\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % name)
    add(ids["fileref:uitest-product"], "B9XControllerUITests.xctest",
        "{\n\t\t\tisa = PBXFileReference;\n\t\t\texplicitFileType = wrapper.cfbundle;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = B9XControllerUITests.xctest;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n\t\t}")
    add(ids["fileref:Info.plist"], "Info.plist",
        "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = text.plist.xml;\n\t\t\tpath = Info.plist;\n\t\t\tsourceTree = \"<group>\";\n\t\t}")
    add(ids["fileref:Assets.xcassets"], "Assets.xcassets",
        "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = folder.assetcatalog;\n\t\t\tpath = Assets.xcassets;\n\t\t\tsourceTree = \"<group>\";\n\t\t}")
    add(ids["fileref:LaunchScreen.storyboard"], "LaunchScreen.storyboard",
        "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = file.storyboard;\n\t\t\tpath = LaunchScreen.storyboard;\n\t\t\tsourceTree = \"<group>\";\n\t\t}")
    for f in firmware:
        name = os.path.basename(f)
        add(ids["fileref:" + f], name,
            "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = file;\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % name)
    for fw in ["CoreBluetooth.framework", "AppIntents.framework"]:
        add(ids["fileref:" + fw], fw,
            "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = wrapper.framework;\n\t\t\tname = %s;\n\t\t\tpath = System/Library/Frameworks/%s;\n\t\t\tsourceTree = SDKROOT;\n\t\t}" % (fw, fw))
    add(ids["fileref:product"], "B9XController.app",
        "{\n\t\t\tisa = PBXFileReference;\n\t\t\texplicitFileType = wrapper.application;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = B9XController.app;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n\t\t}")

    # ---- PBXFrameworksBuildPhase / PBXResourcesBuildPhase / PBXSourcesBuildPhase ----
    fw_files = ",\n".join(
        "\t\t\t\t%s /* %s in Frameworks */" % (ids["buildfile:" + f], f)
        for f in ["CoreBluetooth.framework", "AppIntents.framework"]
    )
    add(ids["frameworks-phase"], "Frameworks",
        "{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n%s\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}" % fw_files)
    res_files = ",\n".join(
        ["\t\t\t\t%s /* Assets.xcassets in Resources */" % ids["buildfile:Assets.xcassets"],
         "\t\t\t\t%s /* LaunchScreen.storyboard in Resources */" % ids["buildfile:LaunchScreen.storyboard"]]
        + ["\t\t\t\t%s /* %s in Resources */" % (ids["buildfile:" + f], os.path.basename(f)) for f in firmware]
    )
    add(ids["resources-phase"], "Resources",
        "{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n%s\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}" % res_files)
    src_files = ",\n".join(
        "\t\t\t\t%s /* %s in Sources */" % (ids["buildfile:" + s], os.path.basename(s))
        for s in sources
    )
    add(ids["sources-phase"], "Sources",
        "{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n%s\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}" % src_files)
    if uitest_sources:
        uitest_src_files = ",\n".join(
            "\t\t\t\t%s /* %s in Sources */" % (ids["uitest-buildfile:" + s], os.path.basename(s))
            for s in uitest_sources
        )
        add(ids["uitest-sources-phase"], "Sources",
            "{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n%s\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}" % uitest_src_files)
        add(ids["uitest-frameworks-phase"], "Frameworks",
            "{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}")

    # ---- PBXGroup ----
    for gname, gfiles in groups.items():
        children = ",\n".join(
            "\t\t\t\t%s /* %s */" % (ids["fileref:" + s], os.path.basename(s))
            for s in gfiles
        )
        add(ids["group-" + gname], gname,
            "{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\n\t\t\t);\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % (children, gname))
    if uitest_sources:
        uitest_children = ",\n".join(
            "\t\t\t\t%s /* %s */" % (ids["uitest-fileref:" + s], os.path.basename(s))
            for s in uitest_sources
        )
        add(ids["group-uitests"], "B9XControllerUITests",
            "{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\n\t\t\t);\n\t\t\tpath = B9XControllerUITests;\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % uitest_children)
    if firmware:
        fw_children = ",\n".join(
            "\t\t\t\t%s /* %s */" % (ids["fileref:" + f], os.path.basename(f))
            for f in firmware
        )
        add(ids["group-Firmware"], "Firmware",
            "{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\n\t\t\t);\n\t\t\tpath = Firmware;\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % fw_children)
    app_children = []
    for gname in ["Protocol", "Models", "BLE", "Controller", "UI", "Intents"] + (["Firmware"] if firmware else []):
        app_children.append("\t\t\t\t%s /* %s */," % (ids["group-" + gname], gname))
    for s in top_level:
        app_children.append("\t\t\t\t%s /* %s */," % (ids["fileref:" + s], os.path.basename(s)))
    app_children.append("\t\t\t\t%s /* Info.plist */," % ids["fileref:Info.plist"])
    app_children.append("\t\t\t\t%s /* Assets.xcassets */," % ids["fileref:Assets.xcassets"])
    app_children.append("\t\t\t\t%s /* LaunchScreen.storyboard */," % ids["fileref:LaunchScreen.storyboard"])
    add(ids["group-app"], "B9XController",
        "{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\n\t\t\t);\n\t\t\tpath = B9XController;\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % "\n".join(app_children))
    add(ids["group-products"], "Products",
        "{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t%s /* B9XController.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % ids["fileref:product"])
    main_children = "\t\t\t\t%s /* B9XController */,\n\t\t\t\t%s /* Products */," % (
        ids["group-app"], ids["group-products"])
    if uitest_sources:
        main_children += "\n\t\t\t\t%s /* B9XControllerUITests */," % ids["group-uitests"]
    add(ids["group-main"], "B9XController",
        "{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}" % main_children)

    # ---- PBXNativeTarget ----
    add(ids["target"], "B9XController",
        "{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"B9XController\" */;\n\t\t\tbuildPhases = (\n\t\t\t\t%s /* Sources */,\n\t\t\t\t%s /* Frameworks */,\n\t\t\t\t%s /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = B9XController;\n\t\t\tproductName = B9XController;\n\t\t\tproductReference = %s /* B9XController.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}" % (
            ids["configlist-target"], ids["sources-phase"], ids["frameworks-phase"],
            ids["resources-phase"], ids["fileref:product"]))
    if uitest_sources:
        add(ids["uitest-proxy"], "PBXContainerItemProxy",
            "{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = %s /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = %s;\n\t\t\tremoteInfo = B9XController;\n\t\t}" % (ids["project"], ids["target"]))
        add(ids["uitest-dependency"], "PBXTargetDependency",
            "{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = %s /* B9XController */;\n\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;\n\t\t}" % (ids["target"], ids["uitest-proxy"]))
        add(ids["uitest-target"], "B9XControllerUITests",
            "{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"B9XControllerUITests\" */;\n\t\t\tbuildPhases = (\n\t\t\t\t%s /* Sources */,\n\t\t\t\t%s /* Frameworks */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t%s /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = B9XControllerUITests;\n\t\t\tproductName = B9XControllerUITests;\n\t\t\tproductReference = %s /* B9XControllerUITests.xctest */;\n\t\t\tproductType = \"com.apple.product-type.ui-testing\";\n\t\t}" % (
                ids["uitest-configlist"], ids["uitest-sources-phase"], ids["uitest-frameworks-phase"],
                ids["uitest-dependency"], ids["fileref:uitest-product"]))

    # ---- XCBuildConfiguration ----
    project_debug = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
        "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++20"',
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
        "CLANG_WARN_STRICT_PROTOTYPES": "YES",
        "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGREGATE",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '("DEBUG=1", "$(inherited)")',
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LOCALIZATION_PREFS_SET": "YES",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "MTL_FAST_MATH": "YES",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    }
    project_release = dict(project_debug)
    project_release.update({
        "COPY_PHASE_STRIP": "YES",
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "ENABLE_TESTABILITY": "NO",
        "GCC_OPTIMIZATION_LEVEL": "s",
        "GCC_PREPROCESSOR_DEFINITIONS": '"$(inherited)"',
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "ONLY_ACTIVE_ARCH": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
        "VALIDATE_PRODUCT": "YES",
    })
    project_release.pop("SWIFT_ACTIVE_COMPILATION_CONDITIONS", None)

    target_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_IDENTITY": '""',
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
        "CURRENT_PROJECT_VERSION": CURRENT_PROJECT_VERSION,
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "B9XController/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks")',
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SDKROOT": "iphoneos",
        "SWIFT_EMBED_LIBRARIES_WITH_INSTALL": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1",
    }
    target_debug = dict(target_common)
    target_debug["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
    target_release = dict(target_common)

    def config(uuid_, name, settings):
        lines = ["\t\t\tbuildSettings = {"]
        for k in sorted(settings):
            lines.append("\t\t\t\t%s = %s;" % (k, settings[k]))
        lines.append("\t\t\t};")
        lines.append("\t\t\tname = %s;" % name)
        body = "{\n\t\t\tisa = XCBuildConfiguration;\n%s\n\t\t}" % "\n".join(lines)
        add(uuid_, name, body)

    config(ids["config-project-debug"], "Debug", project_debug)
    config(ids["config-project-release"], "Release", project_release)
    config(ids["config-target-debug"], "Debug", target_debug)
    config(ids["config-target-release"], "Release", target_release)
    if uitest_sources:
        uitest_common = {
            "CODE_SIGN_IDENTITY": '""',
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "GENERATE_INFOPLIST_FILE": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
            "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@loader_path/Frameworks", "@executable_path/Frameworks")',
            "PRODUCT_BUNDLE_IDENTIFIER": "com.enginecore.plus.uitests",
            "PRODUCT_NAME": '"$(TARGET_NAME)"',
            "SDKROOT": "iphoneos",
            "SUPPORTED_PLATFORMS": '"iphonesimulator iphoneos"',
            "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": "1",
            "TEST_TARGET_NAME": "B9XController",
        }
        uitest_debug = dict(uitest_common)
        uitest_debug["ENABLE_TESTABILITY"] = "YES"
        uitest_debug["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        uitest_release = dict(uitest_common)
        config(ids["uitest-config-debug"], "Debug", uitest_debug)
        config(ids["uitest-config-release"], "Release", uitest_release)

    # ---- XCConfigurationList ----
    for list_id, name, debug_id, release_id in [
        (ids["configlist-project"], "Build configuration list for PBXProject \"B9XController\"",
         ids["config-project-debug"], ids["config-project-release"]),
        (ids["configlist-target"], "Build configuration list for PBXNativeTarget \"B9XController\"",
         ids["config-target-debug"], ids["config-target-release"]),
    ]:
        add(list_id, name,
            "{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}" % (debug_id, release_id))
    if uitest_sources:
        add(ids["uitest-configlist"], "Build configuration list for PBXNativeTarget \"B9XControllerUITests\"",
            "{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}" % (ids["uitest-config-debug"], ids["uitest-config-release"]))

    # ---- PBXProject ----
    project_targets = "\t\t\t\t%s /* B9XController */,\n" % ids["target"]
    if uitest_sources:
        project_targets += "\t\t\t\t%s /* B9XControllerUITests */,\n" % ids["uitest-target"]
    add(ids["project"], "Project object",
        "{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tLastUpgradeCheck = 2600;\n\t\t\t\tTargetAttributes = {\n\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;\n\t\t\t\t\t};\n\t\t\t\t};\n\t\t\t};\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"B9XController\" */;\n\t\t\tcompatibilityVersion = \"Xcode 16.0\";\n\t\t\tdevelopmentRegion = zh_CN;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\tzh_CN,\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = %s;\n\t\t\tproductRefGroup = %s /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n%s\t\t\t);\n\t\t}" % (
            ids["target"], ids["configlist-project"], ids["group-main"],
            ids["group-products"], project_targets))

    # ---- 写出 project.pbxproj ----
    os.makedirs(PROJ_DIR, exist_ok=True)
    lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};",
             "\tobjectVersion = 77;", "\tobjects = {"]
    for uuid_, comment, body in sorted(objects, key=lambda x: x[0]):
        first, _, rest = body.partition("\n")
        lines.append("\t\t%s /* %s */ = %s" % (uuid_, comment, first))
        if rest:
            lines.append(rest)
        # each object entry must end with "};" in pbxproj
        lines[-1] = lines[-1] + ";"
    lines += ["\t};", "\trootObject = %s /* Project object */;" % ids["project"], "}"]
    with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    # ---- Scheme ----
    os.makedirs(SCHEME_DIR, exist_ok=True)
    uitest_build_entry = ""
    uitest_testables = ""
    if uitest_sources:
        uitest_build_entry = """
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "%s"
               BuildableName = "B9XControllerUITests.xctest"
               BlueprintName = "B9XControllerUITests"
               ReferencedContainer = "container:B9XController.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>""" % ids["uitest-target"]
        uitest_testables = """
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "%s"
               BuildableName = "B9XControllerUITests.xctest"
               BlueprintName = "B9XControllerUITests"
               ReferencedContainer = "container:B9XController.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>""" % ids["uitest-target"]
    scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "%s"
               BuildableName = "B9XController.app"
               BlueprintName = "B9XController"
               ReferencedContainer = "container:B9XController.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>%s
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.Debugger.Foundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.Debugger.Foundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">%s
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.Debugger.Foundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.Debugger.Foundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""" % (ids["target"], uitest_build_entry, uitest_testables)
    with open(os.path.join(SCHEME_DIR, "B9XController.xcscheme"), "w", encoding="utf-8") as f:
        f.write(scheme)

    print("generated %s (%d sources)" % (PROJ_DIR, len(sources)))


if __name__ == "__main__":
    main()
