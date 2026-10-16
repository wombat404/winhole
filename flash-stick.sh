#!/bin/bash
# flashes recovery.iso from WSL onto a USB stick attached to the host.
#
# steps:
#   1) enumerate all disks with BusType=USB via Windows PowerShell
#   2) show a numbered list to pick from
#   3) write the ISO via elevated PowerShell to \\.\PhysicalDriveN (triggers UAC)
#
# usage:
#   ./flash-stick.sh                      # uses ./recovery.iso
#   ./flash-stick.sh /path/to/image.iso   # custom source
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# build.sh writes the ISO to /home/simon/recovery.iso by default (see OUT=).
# fallback: project directory.
if [ -n "${1:-}" ]; then
    ISO="$1"
elif [ -f "/home/simon/recovery.iso" ]; then
    ISO="/home/simon/recovery.iso"
elif [ -f "$HERE/recovery.iso" ]; then
    ISO="$HERE/recovery.iso"
else
    echo "recovery.iso not found in /home/simon/ or $HERE."
    echo "Run './rebuild.sh' first or pass a path as argument."
    exit 1
fi
[ -f "$ISO" ] || { echo "ISO not found: $ISO"; exit 1; }
echo ">> ISO: $ISO ($(du -h "$ISO" | cut -f1))"

PS="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
[ -x "$PS" ] || { echo "powershell.exe not found: $PS"; exit 1; }

echo ">> detecting USB disks..."
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
