#!/bin/bash
# flashes recovery.iso onto a USB stick.
#
# runs in two modes:
#   - WSL: finds USB disks via Windows PowerShell and writes to \\.\PhysicalDriveN
#          through an elevated PowerShell window (UAC prompt).
#   - native Linux: finds USB disks via lsblk and writes via dd. sudo is used
#          for the write (and for umount of any mounted partitions on the stick).
#
# usage:
#   ./flash-stick.sh                      # uses ./recovery.iso or /home/<you>/recovery.iso
#   ./flash-stick.sh /path/to/image.iso   # custom source
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# locate the ISO (build.sh writes it to /home/<you>/recovery.iso by default)
if [ -n "${1:-}" ]; then
    ISO="$1"
elif [ -f "$HOME/recovery.iso" ]; then
    ISO="$HOME/recovery.iso"
elif [ -f "$HERE/recovery.iso" ]; then
    ISO="$HERE/recovery.iso"
else
    echo "recovery.iso not found in \$HOME or $HERE."
    echo "Run './build.sh' first or pass a path as argument."
    exit 1
fi
[ -f "$ISO" ] || { echo "ISO not found: $ISO"; exit 1; }
echo ">> ISO: $ISO ($(du -h "$ISO" | cut -f1))"

# detect WSL by checking for the Windows PowerShell under /mnt/c
PS="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
if [ -x "$PS" ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    MODE="wsl"
else
    MODE="linux"
fi
echo ">> mode: $MODE"

# =============================================================================
# linux mode: lsblk + dd
# =============================================================================
if [ "$MODE" = "linux" ]; then
    command -v lsblk >/dev/null 2>&1 || { echo "lsblk not found (util-linux)"; exit 1; }
    command -v dd    >/dev/null 2>&1 || { echo "dd not found (coreutils)";   exit 1; }

    echo ">> detecting USB disks..."
    # lsblk reports TRAN=usb for USB-attached block devices
    LINES="$(lsblk -d -n -b -o NAME,SIZE,MODEL,TRAN 2>/dev/null | awk '$NF=="usb"')"

    if [ -z "${LINES// /}" ]; then
        echo "No USB disks detected. (stick plugged in?)"
        exit 1
    fi

    echo
    echo "Available USB disks:"
    printf "   %-3s %-10s %10s  %s\n" "#" "Device" "GB" "Model"
    printf "   %-3s %-10s %10s  %s\n" "---" "----------" "----------" "------"
    declare -a DEVS SIZES MODELS
    IDX=0
    while read -r NAME SIZE_BYTES REST; do
        [ -z "$NAME" ] && continue
        # the TRAN field is the last token; the model is everything in between
        TRAN="$(echo "$REST" | awk '{print $NF}')"
        MODEL="$(echo "$REST" | awk '{$NF=""; sub(/[ \t]+$/,""); print}')"
        [ "$TRAN" = "usb" ] || continue
        IDX=$((IDX+1))
        DEVS[$IDX]="/dev/$NAME"
        SIZES[$IDX]="$(awk -v b="$SIZE_BYTES" 'BEGIN{printf "%.2f", b/1024/1024/1024}')"
        MODELS[$IDX]="${MODEL:-unknown}"
        printf "   %-3s %-10s %10s  %s\n" "$IDX" "/dev/$NAME" "${SIZES[$IDX]}" "${MODELS[$IDX]}"
    done <<< "$LINES"

    if [ "$IDX" -eq 0 ]; then
        echo "No USB disks detected."
        exit 1
    fi

    echo
    read -rp "Pick (1-$IDX) or empty to cancel: " SEL
    [ -z "${SEL:-}" ] && { echo "cancelled."; exit 0; }
    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "$IDX" ]; then
        echo "invalid pick: $SEL"; exit 1
    fi
    DEV="${DEVS[$SEL]}"
    SIZE="${SIZES[$SEL]}"
    MODEL="${MODELS[$SEL]}"

    echo
    echo "About to write '$ISO' to $DEV ($MODEL, ~${SIZE} GB)."
    echo "All data on $DEV will be destroyed."
    read -rp "Type FLASH to confirm: " CONFIRM
    [ "$CONFIRM" = "FLASH" ] || { echo "cancelled."; exit 0; }

    # unmount any mounted partitions on the device first
    for part in "${DEV}"[0-9]* "${DEV}p"[0-9]*; do
        [ -b "$part" ] || continue
        if mount | grep -q "^$part "; then
            echo ">> unmounting $part"
            sudo umount "$part" || true
        fi
    done

    echo ">> writing (sudo dd), this takes a few minutes..."
    sudo dd if="$ISO" of="$DEV" bs=4M status=progress conv=fsync
    sync
    echo ">> flash-stick done. you can unplug $DEV."
    exit 0
fi

# =============================================================================
# WSL mode: PowerShell on the Windows host
# =============================================================================
echo ">> detecting USB disks via Windows PowerShell..."
LIST="$("$PS" -NoProfile -Command "
    Get-Disk |
      Where-Object { \$_.BusType -eq 'USB' } |
      ForEach-Object { '{0}|{1}|{2}|{3}' -f \$_.Number, \$_.FriendlyName, ([math]::Round(\$_.Size/1GB,2)), \$_.SerialNumber }
" | tr -d '\r')"

if [ -z "${LIST// /}" ]; then
    echo "No USB disks detected. (stick plugged in?)"
    exit 1
fi

echo
echo "Available USB disks:"
printf "   %-3s %-5s %-36s %10s  %s\n" "#" "Disk" "Name" "GB" "Serial"
printf "   %-3s %-5s %-36s %10s  %s\n" "---" "-----" "------------------------------------" "----------" "------"
declare -a NUMS NAMES SIZES
IDX=0
while IFS='|' read -r NUM NAME SIZE SER; do
    [ -z "$NUM" ] && continue
    IDX=$((IDX+1))
    NUMS[$IDX]="$NUM"; NAMES[$IDX]="$NAME"; SIZES[$IDX]="$SIZE"
    printf "   %-3s %-5s %-36s %10s  %s\n" "$IDX" "$NUM" "$NAME" "$SIZE" "$SER"
done <<< "$LIST"

if [ "$IDX" -eq 0 ]; then
    echo "No USB disks detected."
    exit 1
fi

echo
read -rp "Pick (1-$IDX) or empty to cancel: " SEL
[ -z "${SEL:-}" ] && { echo "cancelled."; exit 0; }
if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "$IDX" ]; then
    echo "invalid pick: $SEL"; exit 1
fi
DNUM="${NUMS[$SEL]}"
DNAME="${NAMES[$SEL]}"
DSIZE="${SIZES[$SEL]}"

echo
echo ">> flashing disk #$DNUM ($DNAME, ~${DSIZE} GB) from $ISO ..."
ISO_WIN="$(wslpath -w "$ISO")"
ISO_WIN_ESC="${ISO_WIN//\'/\'\'}"

echo
echo ">> please confirm the UAC prompt (elevated PowerShell is starting) ..."

# PowerShell flash script (runs elevated via Start-Process -Verb RunAs).
# escaped \$ stays as a PowerShell variable, $DNUM / $ISO_WIN_ESC are expanded by bash.
PS_SCRIPT=$(cat <<POWERSHELL
\$ErrorActionPreference = 'Stop'
\$num = ${DNUM}
\$iso = '${ISO_WIN_ESC}'
\$Host.UI.RawUI.WindowTitle = "Flashing recovery.iso -> Disk \$num"
Try {
    Write-Host ">> preparing disk \$num (offline + clear) ..."
    Get-Disk -Number \$num | Set-Disk -IsOffline \$true   -ErrorAction SilentlyContinue
    Get-Disk -Number \$num | Set-Disk -IsReadOnly \$false -ErrorAction SilentlyContinue
    Clear-Disk -Number \$num -RemoveData -RemoveOEM -Confirm:\$false -ErrorAction SilentlyContinue

    Write-Host ">> writing '\$iso' -> \\\\.\\PhysicalDrive\$num ..."
    \$in  = [IO.File]::OpenRead(\$iso)
    \$out = New-Object IO.FileStream("\\\\.\\PhysicalDrive\$num", [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    \$buf = New-Object byte[] (4MB)
    \$written = 0; \$total = \$in.Length
    \$sw = [Diagnostics.Stopwatch]::StartNew()
    while ((\$n = \$in.Read(\$buf, 0, \$buf.Length)) -gt 0) {
        \$out.Write(\$buf, 0, \$n)
        \$written += \$n
        if (\$sw.ElapsedMilliseconds -gt 300) {
            \$pct = [int](100 * \$written / \$total)
            Write-Progress -Activity "Flashing recovery.iso" -Status ("\$([math]::Round(\$written/1MB,0))/\$([math]::Round(\$total/1MB,0)) MB") -PercentComplete \$pct
            \$sw.Restart()
        }
    }
    \$out.Flush(); \$out.Dispose(); \$in.Dispose()
    Write-Progress -Activity "Flashing recovery.iso" -Completed

    Write-Host ""
    Write-Host ("OK: {0:N1} MB written." -f (\$written/1MB)) -ForegroundColor Green
    Try { Get-Disk -Number \$num | Set-Disk -IsOffline \$true -ErrorAction SilentlyContinue } Catch {}
} Catch {
    Write-Host ""
    Write-Host ("ERROR: " + \$_.Exception.Message) -ForegroundColor Red
    \$global:LASTEXITCODE = 1
}
Write-Host ""
Write-Host "Press any key to close this window ..."
[void][System.Console]::ReadKey(\$true)
POWERSHELL
)

# PowerShell -EncodedCommand expects UTF-16LE base64
ENC="$(printf '%s' "$PS_SCRIPT" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"

"$PS" -NoProfile -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand','$ENC')"

echo ">> flash-stick done."
