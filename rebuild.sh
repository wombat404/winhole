#!/bin/bash
# rebuilds everything after a change to init (or similar): initramfs + recovery.iso.
# also builds the PasswordRecovery project (assets/src) as a portable
# single-file EXE into assets/bin/ (via build.sh).
# with --test, runs a visible QEMU boot that verifies install and restore passes.
#
#   ./rebuild.sh                # rebuild only (default), with PasswordRecovery publish
#   ./rebuild.sh --test         # also run install+restore boot test in a QEMU window
#   ./rebuild.sh --cross        # also regenerate the cross sprite sheet
#   ./rebuild.sh --no-exe       # skip the PasswordRecovery publish
#   ./rebuild.sh --clean-exe    # run 'dotnet clean' + remove bin/obj first
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
DO_TEST=0; DO_CROSS=0; DO_EXE=1; DO_CLEAN_EXE=0
for a in "$@"; do
    case "$a" in
        --test)      DO_TEST=1 ;;
        --no-test)   DO_TEST=0 ;;
        --cross)     DO_CROSS=1 ;;
        --no-exe)    DO_EXE=0 ;;
        --clean-exe) DO_CLEAN_EXE=1 ;;
        *) echo "unknown option: $a"; exit 2 ;;
    esac
done

if [ "$DO_CROSS" = 1 ]; then
    echo "== regenerating cross sprite =="
    python3 makecross.py
fi

if [ "$DO_EXE" = 1 ] && [ "$DO_CLEAN_EXE" = 1 ]; then
    echo "== PasswordRecovery: dotnet clean + remove bin/obj =="
    DOTNET="/mnt/c/Program Files/dotnet/dotnet.exe"
    PROJECT="$HERE/assets/src/PRH/PRH.csproj"
    if [ -x "$DOTNET" ] && [ -f "$PROJECT" ]; then
        "$DOTNET" clean "$(wslpath -w "$PROJECT")" -c Release --nologo -v minimal || true
    fi
    rm -rf "$HERE/assets/src/PRH/bin" "$HERE/assets/src/PRH/obj"
fi

echo "== 1) build initramfs + recovery.iso =="
BUILD_ARGS=()
[ "$DO_EXE" = 0 ] && BUILD_ARGS+=(--no-exe)
bash build.sh "${BUILD_ARGS[@]}"

[ "$DO_TEST" = 0 ] && { echo "== done (no test) =="; exit 0; }

# always build a fresh test image for a clean starting state
echo "== 2) regenerate test image =="
bash make_testdisk.sh >/dev/null

# read partition 2 location from GPT instead of hardcoding
P2_START=$(sfdisk -d test.img | grep -oP 'img2.*start=\s*\K[0-9]+')
P2_SIZE=$(sfdisk  -d test.img | grep -oP 'img2.*size=\s*\K[0-9]+')
[ -n "$P2_START" ] && [ -n "$P2_SIZE" ] || { echo "could not read partition 2 location"; exit 1; }
echo "   partition 2: start=$P2_START size=$P2_SIZE"

ISO="/home/simon/recovery.iso"
[ -f "$ISO" ] || { echo "ISO not found: $ISO"; exit 1; }

mkdir -p .mnt
ORIG_HASH=$(md5sum < <(printf 'ORIGINAL utilman.exe sentinel #42\n') | cut -d' ' -f1)
TOOL_HASH=$(md5sum "$HERE/assets/bin/PasswordRecovery.exe" | cut -d' ' -f1)

boot_once() {
    local tag="$1"
    echo "== boot [$tag] in QEMU window (window closes on reboot) =="
    qemu-system-x86_64 -machine q35 -m 1024 \
      -drive file="$ISO",format=raw,if=ide,index=0,media=disk \
      -drive file=test.img,if=none,id=nvm,format=raw \
      -device nvme,serial=deadbeef,drive=nvm \
      -boot c -serial file:.vboot.log -no-reboot || true
}

snapshot_p2() {
    dd if=test.img of=.chk.img bs=512 skip="$P2_START" count="$P2_SIZE" status=none
    ntfs-3g .chk.img .mnt
}

release_p2() {
    fusermount3 -u .mnt; rm -f .chk.img
}

RC=0

# phase A: install
boot_once install
snapshot_p2
UTIL=".mnt/Windows/System32/Utilman.exe"
BAK=".mnt/Windows/System32/Utilman.exe_bak"
H_UTIL=$([ -f "$UTIL" ] && md5sum "$UTIL" | cut -d' ' -f1 || echo MISSING)
H_BAK=$( [ -f "$BAK"  ] && md5sum "$BAK"  | cut -d' ' -f1 || echo MISSING)
echo "   install: Utilman.exe=$H_UTIL  _bak=$H_BAK"
echo "   expected: Utilman.exe=$TOOL_HASH  _bak=$ORIG_HASH"
if [ "$H_UTIL" = "$TOOL_HASH" ] && [ "$H_BAK" = "$ORIG_HASH" ]; then
    echo "   PASS: install replaced Utilman.exe with tool.exe and saved original as _bak"
else
    echo "   FAIL: install phase"
    [ -s .vboot.log ] && sed 's/^/     /' .vboot.log
    RC=1
fi
release_p2

# phase B: restore (second boot, no reset)
if [ "$RC" = 0 ]; then
    boot_once restore
    snapshot_p2
    H_UTIL=$([ -f "$UTIL" ] && md5sum "$UTIL" | cut -d' ' -f1 || echo MISSING)
    H_BAK=$( [ -f "$BAK"  ] && md5sum "$BAK"  | cut -d' ' -f1 || echo GONE)
    echo "   restore: Utilman.exe=$H_UTIL  _bak=$H_BAK"
    echo "   expected: Utilman.exe=$ORIG_HASH  _bak=GONE"
    if [ "$H_UTIL" = "$ORIG_HASH" ] && [ "$H_BAK" = "GONE" ]; then
        echo "   PASS: restore brought back the original from _bak and removed _bak"
    else
        echo "   FAIL: restore phase"
        [ -s .vboot.log ] && sed 's/^/     /' .vboot.log
        RC=1
    fi
    release_p2
fi

rmdir .mnt; rm -f .vboot.log
echo "== recovery.iso: $ISO =="
exit $RC
