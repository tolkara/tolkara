#!/usr/bin/env python3
"""Build one shim dylib per library listed in surface.json (from classify.py).

usage: build_shims.py <ios|iossim> <surface.json|generic> <outdir> [absent.json]

With "generic" there is no surface: one adapter is built per hand-written
translation/<Framework>/ directory, with no stubs for any one executable. That is
what a build not made for a particular application ships; the runtime resolves
libraries by name and synthesises whatever is still missing. A standalone adapter
re-exports nothing, and the leaves marked absent are written to absent.json for
the runtime, which then opens no library of that name. Directories marked
experimental take part only when TOLKARA_EXPERIMENTAL_ADAPTERS names them (see
tools/classify.py).

For library <Leaf>: hand-written sources in translation/<Leaf>/ are compiled first; every
symbol the guest needs that they do not define gets a generated logging stub
(function: log once, return 0; string constant: CFSTR of its own name; class: empty
AKStubObject subclass). Libraries that exist on iOS are re-exported by their shim.
Optional translation/<Leaf>/ldflags holds extra linker flags ({outdir} names
where the adapters are built); a directory with only that file is an adapter too (translation/AudioUnit re-exports the
AudioToolbox adapter: iOS has no AudioUnit library, AudioToolbox carries its API).
"""
import glob, hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from classify import adapter_leaves, translation_leaves
from shim_stubs import function_stub
platform, surface, outdir = sys.argv[1:4]
absent_list = sys.argv[4] if len(sys.argv) > 4 else None
generic = surface == "generic"
ADAPTERS = adapter_leaves()
plan = {"sdk": "", "translation": {}} if generic else json.load(open(surface))
SDKNAME = {"ios": "iphoneos", "iossim": "iphonesimulator"}[platform]
TARGET = {"ios": "arm64-apple-ios17.0", "iossim": "arm64-apple-ios17.0-simulator"}[platform]
SDK = subprocess.run(["xcrun", "--sdk", SDKNAME, "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
CC = ["xcrun", "--sdk", SDKNAME, "clang", "-target", TARGET, "-isysroot", SDK, "-O1", "-g", "-fobjc-arc",
      "-I", os.path.join(ROOT, "translation/AKSupport"), "-Wno-deprecated-declarations"]
if generic:
    plan["sdk"] = SDK   # sdk_tbd() below rewrites paths from the SDK classify used
gen = os.path.join(ROOT, "build/gen", platform); os.makedirs(gen, exist_ok=True); os.makedirs(outdir, exist_ok=True)


# Compatibility libraries change less often than the runtime. Cache unsigned
# link outputs; the packaging step still signs each copied output for the app.
identity = hashlib.sha256(Path(__file__).read_bytes())
identity.update((Path(ROOT) / "tools/shim_stubs.py").read_bytes())
identity.update(json.dumps([platform, plan, CC, sorted(ADAPTERS)], sort_keys=True).encode())
identity.update(subprocess.check_output(["xcrun", "--sdk", SDKNAME, "--show-sdk-build-version"]))
identity.update(subprocess.check_output(["xcrun", "clang", "--version"]))
for source in sorted((Path(ROOT) / "translation").rglob("*")):
    if source.is_file():
        identity.update(str(source.relative_to(ROOT)).encode()); identity.update(source.read_bytes())
cache = Path(ROOT) / "build/shim-cache" / platform / identity.hexdigest()
cache.mkdir(parents=True, exist_ok=True)


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit("FAILED: " + " ".join(cmd) + "\n" + r.stdout + r.stderr)


def sdk_tbd(path):   # classify ran against the device SDK; map into the SDK we link with
    p = path.replace(plan["sdk"], SDK)
    return p if os.path.exists(p) else None


built, building = set(), set()


def build(leaf, install_name, symbols, real_tbd=None, provider_tbds=(), extra=()):
    if leaf in built:
        return
    if leaf in building:
        sys.exit(f"adapter dependency cycle at {leaf}")
    building.add(leaf)
    d = re.sub(r"\.dylib$", "", leaf)
    fl = os.path.join(ROOT, "translation", d, "ldflags")
    flags = Path(fl).read_text().split() if os.path.exists(fl) else []
    # Re-exported adapters must exist even when the classified executable
    # imports only their consumer (AudioUnit re-exports AudioToolbox).
    for dependency in re.findall(r"\{outdir\}/ak([^/\s,]+)\.dylib", " ".join(flags)):
        if dependency not in ADAPTERS:
            sys.exit(f"{leaf}: unavailable adapter dependency {dependency}")
        planned = plan["translation"].get(dependency)
        if planned:
            build(dependency, planned["install_name"], planned["symbols"],
                  planned["real_tbd"], planned["provider_tbds"])
        else:
            build(dependency, f"@rpath/ak{dependency}.dylib", [],
                  None if dependency in translation_leaves("standalone") else sdk_library(dependency))
    out = os.path.join(outdir, os.path.basename(install_name))
    cached = cache / os.path.basename(install_name)
    if cached.is_file():
        shutil.copy2(cached, out)
        building.remove(leaf); built.add(leaf)
        print(f"  {os.path.basename(out):32s} cached compatibility library")
        return
    objs, defined = [], set()
    # An experimental adapter nobody opted into contributes no sources.
    for src in sorted(glob.glob(os.path.join(ROOT, "translation", d, "*.[cm]"))) if d in ADAPTERS else []:
        o = os.path.join(gen, d + "_" + os.path.basename(src) + ".o")
        run(CC + ["-c", src, "-o", o]); objs.append(o)
        nm = subprocess.run(["xcrun", "nm", "-gUj", o], capture_output=True, text=True).stdout
        defined.update(nm.split())
    todo = [(s, k) for s, k, prov in symbols if s not in defined and not prov]
    classes = sorted({s.split("$_", 1)[1] for s, k in todo if k in ("class", "metaclass")})
    lines = ['#import "AKSupport.h"', "// generated by tools/build_shims.py; do not edit", ""]
    for c in classes:
        lines.append(f"@interface {c} : AKStubObject @end @implementation {c} @end")
    for s, k in todo:
        c = s[1:]
        if k == "func":
            lines.append(function_stub(s))
        elif k == "data":   # 64 bytes: a CFString pointer for constant-like names, zeros otherwise
            init = f'CFSTR("{c}")' if re.match(r"(k[A-Z]|NS|MTL|AV|CG|UI)", c) else "0"
            lines.append(f"struct {{ const void *p; char pad[56]; }} {c} = {{ {init} }};")
    stub = os.path.join(gen, d + "_stubs.m"); open(stub, "w").write("\n".join(lines) + "\n")
    o = stub + ".o"; run(CC + ["-c", stub, "-o", o]); objs.append(o)
    out = os.path.join(outdir, os.path.basename(install_name))
    ld = ["-dynamiclib", "-install_name", install_name, "-o", out]
    # Resolve through compatibility adapters before native providers. Their
    # re-exports retain the native APIs while overriding desktop semantics.
    adapter_reexports = [flag for flag in flags if flag.startswith("-Wl,-reexport_library,")]
    ld += [flag.replace("{outdir}", outdir) for flag in adapter_reexports]
    for t in [real_tbd, *provider_tbds]:   # re-exports first: ld keeps the first mention of a dylib
        t = t and sdk_tbd(t)
        if t:
            ld += [f"-Wl,-reexport_library,{t}"]
    ld += ["-framework", "Foundation", "-framework", "CoreFoundation"]
    if leaf != "AKSupport":
        ld += ["-L", outdir, "-lAKSupport"]
    ld += [flag.replace("{outdir}", outdir) for flag in flags if flag not in adapter_reexports]
    run(CC + objs + ld + list(extra))
    if real_tbd and "LC_REEXPORT_DYLIB" not in subprocess.run(["otool", "-l", out], capture_output=True, text=True).stdout:
        sys.exit(f"{out}: re-export of the real library was not recorded")
    shutil.copy2(out, cached)
    building.remove(leaf); built.add(leaf)
    print(f"  {os.path.basename(out):32s} hand={len(defined):3d} stubs={len(todo):3d}" + (" reexports real" if real_tbd else ""))


def sdk_library(leaf):
    """The iOS library of the same name, so an adapter re-exports what exists."""
    for candidate in (f"{SDK}/System/Library/Frameworks/{leaf}.framework/{leaf}.tbd",
                      f"{SDK}/usr/lib/{leaf}.tbd"):
        if os.path.exists(candidate):
            return candidate
    return None


build("AKSupport", "@rpath/libAKSupport.dylib", [])
for leaf, p in plan["translation"].items():
    build(leaf, p["install_name"], p["symbols"], p["real_tbd"], p["provider_tbds"])
# Generic: every hand-written framework, with no stubs for any executable.
if generic:
    written = os.path.join(ROOT, "translation")
    standalone, absent = translation_leaves("standalone"), translation_leaves("absent")
    for leaf in sorted(ADAPTERS - absent):
        directory = os.path.join(written, leaf)
        # An adapter is sources, or only linker flags (one that re-exports another adapter).
        if leaf == "AKSupport" or not any(f.endswith((".c", ".m")) or f == "ldflags" for f in os.listdir(directory)):
            continue
        build(leaf, f"@rpath/ak{leaf}.dylib", [], None if leaf in standalone else sdk_library(leaf))
    if absent_list:
        if absent:
            with open(absent_list, "w") as f:
                json.dump(sorted(absent), f, indent=1)
        elif os.path.exists(absent_list):
            os.remove(absent_list)
