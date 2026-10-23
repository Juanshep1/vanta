#!/usr/bin/env python3
"""Builds a Vanta game as an iPhone/iPad app.

    python3 native/vantac.py game.va --ios -o out/Game.app [--bundle-id com.you.game] [--name "Game"]
                               [--resources dir1,dir2] [--icon icon.png]

What it does: compiles the program to C (the same way as a desktop build), compiles that plus the Vanta
runtime and the game runtime with the iOS SDK, links SDL2 for iOS, writes the .app bundle (Info.plist that
shows the app's Documents folder in the Files app, so players can drop data files in), copies resource
folders next to the executable, and signs it with a development identity + provisioning profile.

Needs: Xcode, an SDL2 static library built for iOS (VANTA_SDL_IOS=dir with lib/libSDL2.a and include/),
and for signing an "Apple Development" identity in the keychain plus a matching provisioning profile
(VANTA_IOS_PROFILE=path, or the newest one in ~/Library/MobileDevice/Provisioning Profiles that covers the
bundle ID). VANTA_IOS_IDENTITY picks the signing identity (SHA-1 or name); otherwise the profile's own is used.
"""
import glob, hashlib, os, plistlib, shutil, subprocess, sys, tempfile

RUNTIME = os.path.join(os.path.dirname(os.path.abspath(__file__)), "runtime")
SDL_IOS = os.environ.get("VANTA_SDL_IOS", os.path.expanduser("~/projects/ref/sdl-ios/out"))
FRAMEWORKS = ["UIKit", "Foundation", "CoreGraphics", "QuartzCore", "OpenGLES", "Metal", "CoreAudio", "AudioToolbox",
              "AVFoundation", "GameController", "CoreMotion", "CoreHaptics", "CoreBluetooth"]


def run(cmd, what):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"Oops! {what} failed:\n" + (r.stderr or r.stdout)[-4000:])
        sys.exit(1)
    return r.stdout


def profiles():
    out = []
    for p in glob.glob(os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles/*.mobileprovision")):
        try:
            raw = subprocess.run(["security", "cms", "-D", "-i", p], capture_output=True, check=True).stdout
            out.append((p, plistlib.loads(raw)))
        except Exception:
            continue
    return out


def pick_profile(bundle_id):
    chosen = os.environ.get("VANTA_IOS_PROFILE")
    if chosen:
        raw = subprocess.run(["security", "cms", "-D", "-i", chosen], capture_output=True, check=True).stdout
        return chosen, plistlib.loads(raw)
    best = None
    for p, info in profiles():
        app_id = info.get("Entitlements", {}).get("application-identifier", "")
        team = info.get("TeamIdentifier", [""])[0]
        pattern = app_id[len(team) + 1:] if app_id.startswith(team + ".") else app_id
        ok = pattern == "*" or pattern == bundle_id or (pattern.endswith(".*") and bundle_id.startswith(pattern[:-1]))
        if ok and (best is None or info["ExpirationDate"] > best[1]["ExpirationDate"]):
            best = (p, info)
    if not best:
        print(f"Oops! no provisioning profile covers {bundle_id}")
        sys.exit(1)
    return best


def pick_identity(profile):
    want = os.environ.get("VANTA_IOS_IDENTITY")
    if want:
        return want
    certs = [hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])]
    found = run(["security", "find-identity", "-v", "-p", "codesigning"], "listing signing identities")
    for line in found.splitlines():
        parts = line.split()
        if len(parts) > 1 and parts[1] in certs:
            return parts[1]
    print("Oops! no signing identity in the keychain matches the provisioning profile")
    sys.exit(1)


def build_ios(comp, out_app, name, bundle_id, resources, icon, flags):
    if not os.path.isfile(os.path.join(SDL_IOS, "lib", "libSDL2.a")):
        print(f"Oops! SDL2 for iOS not found in {SDL_IOS} (set VANTA_SDL_IOS)")
        sys.exit(1)
    work = out_app.rstrip("/") + ".build"
    os.makedirs(work, exist_ok=True)
    header, chunks, main_src = comp.split_sources(max(1, (os.cpu_count() or 4)))
    sources = []
    for fname, text in [("prog.h", header), ("main.c", main_src)] + [(f"part{i}.c", c) for i, c in enumerate(chunks)]:
        path = os.path.join(work, fname)
        if not (os.path.exists(path) and open(path).read() == text):
            with open(path, "w") as f:
                f.write(text)
        if fname.endswith(".c"):
            sources.append(path)
    sources += [os.path.join(RUNTIME, n) for n in ("vrt.c", "vrt_builtins.c", "vrt_core.c", "vrt_big.c", "vgame.c", "vcanvas.c", "vstb.c", "vgame_ios.m")]
    # optional runtime files the program uses (threads, sockets, sqlite, ...); iOS has no libcurl, so http_get & co
    # aren't available in phone builds
    _vc = sys.modules.get("__main__")
    if not hasattr(_vc, "optional_runtime"):
        import vantac as _vc
    opt_files, opt_libs = _vc.optional_runtime(comp.used_builtins)
    if any(os.path.basename(f) == "vrt_http.c" for f in opt_files):
        print("Oops! http_get/http_post/http_request/download aren't available in iPhone builds yet (no libcurl on iOS)")
        sys.exit(1)
    sources += opt_files
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], "finding the iOS SDK").strip()
    cc = ["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-miphoneos-version-min=15.0", "-isysroot", sdk]
    objs, procs = [], []
    for src in sources:
        obj = os.path.join(work, os.path.splitext(os.path.basename(src))[0] + ".o")
        objs.append(obj)
        if os.path.exists(obj) and os.path.getmtime(obj) >= max(os.path.getmtime(src), os.path.getmtime(os.path.join(work, "prog.h")), os.path.getmtime(os.path.join(RUNTIME, "vrt.h"))):
            continue
        lang = ["-fobjc-arc"] if src.endswith(".m") else ["-std=c11"]
        cmd = cc + [*flags, *lang, "-w", "-I", RUNTIME, "-I", work, "-I", os.path.join(SDL_IOS, "include"),
                    "-Dmain=SDL_main", "-c", src, "-o", obj]
        procs.append((src, subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)))
        if len(procs) >= (os.cpu_count() or 4):
            src0, p0 = procs.pop(0)
            if p0.wait() != 0:
                print("Oops! the C compiler failed:\n" + p0.stderr.read()[-4000:]); sys.exit(1)
    for src0, p0 in procs:
        if p0.wait() != 0:
            print("Oops! the C compiler failed:\n" + p0.stderr.read()[-4000:]); sys.exit(1)
    exe_name = "".join(ch for ch in name if ch.isalnum()) or "VantaGame"
    taken = {os.path.basename(r.rstrip("/")).lower() for r in resources if r}
    while exe_name.lower() in taken:            # the Mac's file system ignores case: keep clear of resource folders
        exe_name += "App"
    if os.path.exists(out_app):
        shutil.rmtree(out_app)
    os.makedirs(out_app)
    link = cc + objs + [os.path.join(SDL_IOS, "lib", "libSDL2.a"), "-liconv", "-lm"]
    link += opt_libs
    for fw in FRAMEWORKS:
        link += ["-framework", fw]
    run(link + ["-o", os.path.join(out_app, exe_name)], "linking")
    info = {
        "CFBundleIdentifier": bundle_id, "CFBundleExecutable": exe_name, "CFBundleName": name,
        "CFBundleDisplayName": name, "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1", "CFBundleInfoDictionaryVersion": "6.0", "MinimumOSVersion": "15.0",
        "CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [1, 2], "LSRequiresIPhoneOS": True,
        "UILaunchScreen": {}, "UIStatusBarHidden": True, "UIRequiresFullScreen": True,
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
        "UIApplicationSupportsIndirectInputEvents": True,
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False, "UISceneConfigurations": {
            "UIWindowSceneSessionRoleApplication": [{"UISceneConfigurationName": "Default", "UISceneDelegateClassName": "VantaSceneDelegate"}]}}, "GCSupportsControllerUserInteraction": True,
        "DTPlatformName": "iphoneos", "DTSDKName": "iphoneos",
    }
    if icon:
        shutil.copy(icon, os.path.join(out_app, "AppIcon60x60@2x.png"))
        shutil.copy(icon, os.path.join(out_app, "AppIcon76x76@2x~ipad.png"))
        info["CFBundleIcons"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60"], "CFBundleIconName": "AppIcon"}}
        info["CFBundleIcons~ipad"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"], "CFBundleIconName": "AppIcon"}}
    with open(os.path.join(out_app, "Info.plist"), "wb") as f:
        plistlib.dump(info, f)
    for res in resources:
        if not res:
            continue
        dst = os.path.join(out_app, os.path.basename(res.rstrip("/")))
        if os.path.isdir(res):
            shutil.copytree(res, dst, ignore=shutil.ignore_patterns("*.va", "tools", "__pycache__", "_check_*"))
        else:
            shutil.copy(res, dst)
    prof_path, prof = pick_profile(bundle_id)
    shutil.copy(prof_path, os.path.join(out_app, "embedded.mobileprovision"))
    team = prof.get("TeamIdentifier", [""])[0]
    ents = {"application-identifier": f"{team}.{bundle_id}", "com.apple.developer.team-identifier": team,
            "get-task-allow": True, "keychain-access-groups": [f"{team}.{bundle_id}"]}
    ent_path = os.path.join(work, "entitlements.plist")
    with open(ent_path, "wb") as f:
        plistlib.dump(ents, f)
    run(["codesign", "--force", "--sign", pick_identity(prof), "--entitlements", ent_path, "--timestamp=none", out_app], "signing")
    print(f"built {out_app} ({bundle_id})")
    return out_app
