"""Add WebRTC capability (webrtc/dtls/nice/srtp plugins + runtime deps) to the
bundled ARM64 GStreamer tree in assets/gstreamer/macos-arm64.

Source can be the official pkg extraction OR a Homebrew prefix (1.28.x plugins
load on a 1.28.7 core — only major.minor must match). Every missing runtime
dependency is copied into lib/ and any absolute Homebrew load path is rewritten
to @rpath/<basename> so the bundle is self-contained (no /opt/homebrew needed
at runtime — a hardcoded absolute path would break on clean machines and trip
the media.ts Homebrew-build heuristic).

Usage: python3 scripts/prepare-webrtc-gstreamer.py <root> [arch] [seed...]
  <root>  directory searched recursively for plugins and dependency dylibs
          (e.g. build/gst-official/runtime or /opt/homebrew)
  [arch]  arm64 (default) | universal | keep
  [seed]  dependency names force-copied (overwrite) before the BFS walk —
          e.g. the glib family when a source lib needs a newer gio than the
          bundled one provides
"""
import pathlib, re, shutil, subprocess, sys
from typing import Optional

PLUGINS = ['libgstwebrtc.dylib', 'libgstdtls.dylib', 'libgstnice.dylib', 'libgstsrtp.dylib']
BREW_MARK = '/opt/homebrew/'

def otool_lines(binary: pathlib.Path) -> list[str]:
    out = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    return re.findall(r'\t(\S+)', out)

def dep_basename(dep: str) -> Optional[str]:
    """Deps we must own: @rpath/X and absolute Homebrew paths. System libs -> None."""
    if dep.startswith('@rpath/'):
        return dep.split('/', 1)[1]
    if BREW_MARK in dep:
        return dep.rsplit('/', 1)[1]
    return None

def find_file(root: pathlib.Path, name: str) -> Optional[pathlib.Path]:
    matches = [p for p in root.rglob(name) if p.is_file()]
    return matches[0] if matches else None

def main() -> None:
    root = pathlib.Path(sys.argv[1])
    arch = sys.argv[2] if len(sys.argv) > 2 else 'arm64'
    seeds = sys.argv[3:]
    dest_lib = pathlib.Path('assets/gstreamer/macos-arm64/lib')
    dest_plugins = dest_lib / 'gstreamer-1.0'
    binaries: list[pathlib.Path] = []

    # Force-copy seeds (newer glib family etc.) before the walk so plugins
    # depending on them resolve against the upgraded versions.
    for name in seeds:
        src = find_file(root, name)
        if not src:
            raise SystemExit(f'Seed not found under {root}: {name}')
        dest = dest_lib / name
        shutil.copyfile(src, dest)
        binaries.append(dest)
        print(f'seed: {name} -> {dest}')

    for name in PLUGINS:
        src = find_file(root, name)
        if not src:
            raise SystemExit(f'Plugin not found under {root}: {name}')
        target = dest_plugins / name
        if arch in ('arm64', 'universal'):
            shutil.copyfile(src, target)
        else:
            thin = dest_plugins / f'.{name}.{arch}.thin'
            subprocess.run(['lipo', str(src), '-thin', arch, '-output', str(thin)], check=True)
            shutil.copyfile(thin, target)
            thin.unlink()
        binaries.append(target)

    # BFS: copy every missing runtime dep, then rewrite absolute Homebrew load
    # paths to @rpath/<basename> on the copy (system deps left untouched).
    # Rewriting is independent of copy dedup: the same basename may first be
    # seen as @rpath (no rewrite needed) and later as an absolute brew path.
    queue, copied = list(binaries), set()
    while queue:
        binary = queue.pop()
        for dep in otool_lines(binary):
            base = dep_basename(dep)
            if not base:
                continue
            dest = dest_lib / base
            if base not in copied:
                copied.add(base)
                if not dest.exists():
                    src = find_file(root, base)
                    if not src:
                        raise SystemExit(f'Missing runtime dependency: {base} (referenced by {binary.name})')
                    shutil.copyfile(src, dest)
                    binaries.append(dest)
                    queue.append(dest)
            if not dep.startswith('@rpath/'):
                subprocess.run(['install_name_tool', '-change', dep, f'@rpath/{base}', str(binary)], check=True)

    # Rpaths: plugins (lib/gstreamer-1.0) reach lib via ..; libs reach siblings.
    # Also normalize each dylib's own install id (otool -L first line) so no
    # source-prefix path survives anywhere (absolute-path heuristics, etc).
    # Repair sweep runs over the WHOLE bundled tree: libs copied by earlier
    # runs may still carry stale absolute load paths inside (they are only
    # referenced via @rpath today, so the BFS above never revisits them).
    sweep = [*dest_lib.glob('*.dylib'), *dest_plugins.glob('*.dylib')]
    for binary in sweep:
        rpath = '@loader_path/..' if binary.parent == dest_plugins else '@loader_path'
        load_commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
        for dep in otool_lines(binary):
            if BREW_MARK in dep:
                base = dep.rsplit('/', 1)[1]
                subprocess.run(['install_name_tool', '-change', dep, f'@rpath/{base}', str(binary)], check=True)
        if f'path {rpath} (offset' not in load_commands:
            subprocess.run(['install_name_tool', '-add_rpath', rpath, str(binary)], check=True)
        subprocess.run(['install_name_tool', '-id', f'@rpath/{binary.name}', str(binary)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
    print(f'Repaired/signed {len(sweep)} binaries under {dest_lib.parent}')

if __name__ == '__main__':
    main()
