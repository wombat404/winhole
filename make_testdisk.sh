#!/bin/bash
# builds a GPT test disk image:
#   part1: Microsoft reserved
#   part2: NTFS with Windows/System32/ntoskrnl.exe and a stub Windows/System32/Utilman.exe
# works without sudo (NTFS is populated inside a partition image via ntfs-3g FUSE).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISK="$HERE/test.img"
PART="$HERE/part2.img"
MNT="$HERE/mnt_test"

SEC=512
TOTAL=819200          # 400 MiB
P1_START=2048; P1_SIZE=2048
P2_START=4096
P2_SIZE=$(( TOTAL - P2_START - 34 ))
GUID_MSR="E3C9E316-0B5C-4DB8-817D-F92DF00215AE"
GUID_BDP="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

rm -f "$DISK" "$PART"; rm -rf "$MNT"; mkdir -p "$MNT"

# build and populate the NTFS partition image
truncate -s $(( P2_SIZE * SEC )) "$PART"
mkfs.ntfs -F -Q -L WIN "$PART" >/dev/null
ntfs-3g "$PART" "$MNT"
mkdir -p "$MNT/Windows/System32"
printf 'FAKE ntoskrnl for test\n'            > "$MNT/Windows/System32/ntoskrnl.exe"
printf 'ORIGINAL utilman.exe sentinel #42\n' > "$MNT/Windows/System32/Utilman.exe"
sync
fusermount3 -u "$MNT"
rmdir "$MNT"

# assemble the GPT disk
truncate -s $(( TOTAL * SEC )) "$DISK"
sfdisk --no-tell-kernel "$DISK" >/dev/null <<EOF
label: gpt
start=$P1_START, size=$P1_SIZE, type=$GUID_MSR, name="Microsoft reserved"
start=$P2_START, size=$P2_SIZE, type=$GUID_BDP, name="Basic data"
EOF
dd if="$PART" of="$DISK" bs=$SEC seek=$P2_START conv=notrunc status=none
rm -f "$PART"

echo ">> test disk: $DISK ($(du -h "$DISK" | cut -f1))"
echo ">> partitions:"; sfdisk -d "$DISK" | sed 's/^/   /'
