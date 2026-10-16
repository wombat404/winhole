#!/bin/bash
# builds initramfs and a bootable recovery.iso (BIOS + UEFI) without sudo.
# also builds the PasswordRecovery project (assets/src) as a portable
# single-file EXE into assets/bin/.
#
# flags:
#   --no-exe   skip the PasswordRecovery publish (fast iteration on init/initramfs)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="$(ls -1 /lib/modules | grep -v microsoft | head -1)"
IRD="$HERE/initramfs"
OUT="/home/simon/recovery.iso"

DO_EXE=1
for a in "$@"; do
    case "$a" in
        --no-exe) DO_EXE=0 ;;
        *) echo "unknown option: $a"; exit 2 ;;
    esac
done

echo ">> kernel: $KVER"

# build PasswordRecovery.exe from assets/src (portable, single-file, self-contained)
if [ "$DO_EXE" = 1 ]; then
    echo ">> publishing PasswordRecovery.exe from assets/src (portable, self-contained)..."
    DOTNET="/mnt/c/Program Files/dotnet/dotnet.exe"
    [ -x "$DOTNET" ] || { echo "!! dotnet.exe not found: $DOTNET"; exit 1; }
    PROJECT="$HERE/assets/src/PRH/PRH.csproj"
    OUTDIR="$HERE/assets/bin"
    [ -f "$PROJECT" ] || { echo "!! PRH.csproj not found: $PROJECT"; exit 1; }
    PROJECT_WIN="$(wslpath -w "$PROJECT")"
    OUTDIR_WIN="$(wslpath -w "$OUTDIR")"
    # clear old publish artifacts
    find "$OUTDIR" -mindepth 1 -maxdepth 1 ! -name '.*' -exec rm -rf {} +
    "$DOTNET" publish "$PROJECT_WIN" \
        -c Release \
        -o "$OUTDIR_WIN" \
        --nologo -v minimal
    [ -f "$OUTDIR/PasswordRecovery.exe" ] || { echo "!! publish did not produce PasswordRecovery.exe"; exit 1; }
    # drop pdb, keep only the portable EXE
    rm -f "$OUTDIR"/*.pdb
    echo ">> PasswordRecovery.exe: $(du -h "$OUTDIR/PasswordRecovery.exe" | cut -f1)"
else
    echo ">> skipping PasswordRecovery publish (--no-exe)"
    [ -f "$HERE/assets/bin/PasswordRecovery.exe" ] || { echo "!! assets/bin/PasswordRecovery.exe missing"; exit 1; }
fi

# busybox and applet symlinks
cp -f "$(command -v busybox)" "$IRD/bin/busybox"
chmod +x "$IRD/bin/busybox"
for a in sh mount umount insmod mkdir ls cat echo sleep kill basename tr sync \
         reboot clear sed cp grep printf test true false; do
    ln -sf busybox "$IRD/bin/$a"
done

# init executable
cp -f "$HERE/init" "$IRD/init"
chmod +x "$IRD/init"

# payload files (copied to the windows partition later)
mkdir -p "$IRD/payload"
cp -f "$HERE/assets/bin/PasswordRecovery.exe" "$IRD/payload/tool.exe"

# compile fbanim statically
gcc -static -O2 "$HERE/fbanim.c" -o "$IRD/anim/fbanim"
strip "$IRD/anim/fbanim" || true

# generate animation frames (frames.bin + frames_installing.bin + frames_restoring.bin)
rm -f "$IRD/anim/frames.bin" "$IRD/anim/frames_"*.bin
python3 "$HERE/make_frames.py"

# unpack kernel modules (.ko.xz / .ko.zst -> .ko) under the expected names
rm -f "$IRD/modules/"*.ko
for m in nvme-auth nvme-core nvme scsi_common scsi_mod libata libahci ahci vmd ntfs3; do
    f=$(find "/lib/modules/$KVER" -name "$m.ko.xz" -o -name "$m.ko.zst" -o -name "$m.ko" 2>/dev/null | head -1)
    if [ -z "$f" ]; then echo "!! module $m not found"; continue; fi
    case "$f" in
        *.ko.xz)  xz  -dc "$f" > "$IRD/modules/$m.ko" ;;
        *.ko.zst) zstd -dc "$f" > "$IRD/modules/$m.ko" ;;
        *.ko)     cp "$f"      "$IRD/modules/$m.ko" ;;
    esac
    echo "   module: $m.ko"
done

# pack initramfs (cpio newc + zstd)
( cd "$IRD" && find . | cpio -o -H newc 2>/dev/null | zstd -15 -T0 -q -f -o "$HERE/initrd.img" )
echo ">> initrd: $(du -h "$HERE/initrd.img" | cut -f1)"

# ISO tree
ISO="$HERE/iso"
rm -rf "$ISO"
mkdir -p "$ISO/boot/grub"
cp "/boot/vmlinuz-$KVER" "$ISO/boot/vmlinuz"
cp "$HERE/initrd.img"    "$ISO/boot/initrd.img"
cat > "$ISO/boot/grub/grub.cfg" <<'EOF'
set timeout=0
set default=0
insmod all_video
insmod gfxterm
set gfxmode=1024x768x32
set gfxpayload=keep
terminal_output gfxterm
menuentry "Windows Recovery" {
    linux /boot/vmlinuz quiet loglevel=0 vt.global_cursor_default=0 console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
EOF

# build ISO (BIOS + UEFI)
grub-mkrescue -o "$OUT" "$ISO" 2>/dev/null
echo ">> ISO ready: $OUT ($(du -h "$OUT" | cut -f1))"
