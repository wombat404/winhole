# Winhole

A bootable USB stick that lets you reset a local Windows user's password on a
machine you own but got locked out of.

Winhole swaps `C:\Windows\System32\Utilman.exe` with a small Windows Forms tool.
When you boot Windows afterwards and click the accessibility icon on the lock
screen, the tool opens with system privileges, lists local accounts, and lets
you set a new password for one of them. A second boot from the stick restores
the original `Utilman.exe`.

Only use this on machines and accounts that are yours.

---

## How it works

1. The stick boots a tiny Linux (BusyBox + a static framebuffer animation).
2. The init script looks for the one NTFS partition that holds
   `Windows\System32\ntoskrnl.exe`.
3. If `Utilman.exe_bak` exists next to `Utilman.exe`, it is **restore mode**:
   the backup is moved back in place.
4. Otherwise it is **install mode**: `Utilman.exe` is saved as
   `Utilman.exe_bak` and replaced by the payload tool.
5. The machine reboots. You boot Windows normally, click the accessibility
   icon on the login screen, pick a user, set a new password.
6. Boot the stick a second time to put the original `Utilman.exe` back.

## Hard requirement: BitLocker must be OFF

Winhole mounts the Windows partition read-write from Linux using `ntfs3`. A
BitLocker-encrypted system partition cannot be opened this way, and even if it
could, writing to it would leave the volume in an unrecoverable state. If
BitLocker is active, Winhole simply refuses the operation and reboots.

**Before you flash the stick:** turn BitLocker off on the Windows machine
you want to recover. See [Turning BitLocker off and on](#turning-bitlocker-off-and-on)
below.

After you are done recovering the account, **turn BitLocker back on**.
Leaving a drive unencrypted is a real risk, not a formality.

---

## Repository layout

```
init                 BusyBox shell init that drives the swap/restore
fbanim.c             Static framebuffer animation player
make_frames.py       Builds the three raw frame files for the animation
makecross.py         Builds the sprite sheet from the cross icon (optional)
make_testdisk.sh     Builds a fake GPT/NTFS test image (used by rebuild.sh --test)
build.sh             Builds initramfs + recovery.iso
rebuild.sh           Rebuilds everything, optional QEMU install+restore test
flash-stick.sh       Flashes recovery.iso onto a USB stick (via Windows PowerShell)
grab.py              Debug helper: screendumps from QEMU over QMP
assets/src/PRH/      The C# WinForms tool that runs as Utilman.exe
assets/bin/          Published PasswordRecovery.exe lives here
initramfs/           Staged initramfs tree
```

---

## Building

The build is a Linux build. On Windows you need WSL (there is no native
Windows path). The `flash-stick.sh` script talks to the host's PowerShell
from inside WSL, so WSL is also the natural place to run it from.

### On Linux (native)

Tested on Debian 13 under WSL2. On a native Linux machine the same packages
apply.

```bash
sudo apt install -y busybox-static gcc cpio zstd xz-utils grub-pc-bin \
                    grub-efi-amd64-bin xorriso mtools ntfs-3g python3-pil \
                    sfdisk qemu-system-x86 fuse3
```

You also need a Linux kernel installed whose modules live under
`/lib/modules/<version>/`. The build picks the first one it finds that is not
flagged `microsoft`.

Build the ISO:

```bash
./build.sh --no-exe       # if you do not have .NET and already have the EXE
./build.sh                # full build, also publishes PasswordRecovery.exe
```

The ISO lands at `/home/<you>/recovery.iso`.

For the `.NET` publish step `build.sh` calls Windows' `dotnet.exe` via
`/mnt/c/...`. That path only exists under WSL. On a native Linux box, pass
`--no-exe` and either build `assets/bin/PasswordRecovery.exe` yourself or
drop in a pre-built one.

### On Windows (through WSL)

1. Install WSL and a Debian-based distro:

   ```powershell
   wsl --install -d Debian
   ```

2. Open the WSL shell. Install the Linux build dependencies as shown above.

3. Install .NET on Windows if you want `build.sh` to publish the tool for
   you. The build calls `C:\Program Files\dotnet\dotnet.exe` through
   `/mnt/c/Program Files/dotnet/dotnet.exe`.

4. Clone and build:

   ```bash
   git clone https://github.com/<your-user>/winhole.git
   cd winhole
   ./build.sh
   ```

The ISO ends up at `/home/<you>/recovery.iso` inside WSL. From Windows you
can reach it under `\\wsl.localhost\Debian\home\<you>\recovery.iso` in
Explorer.

---

## Testing the ISO (without touching real hardware)

```bash
./rebuild.sh --test
```

This builds a 400 MiB GPT disk image with a fake Windows partition
(`Windows\System32\ntoskrnl.exe` + a stub `Utilman.exe`), boots the ISO in a
QEMU window against that image, and verifies the result by md5 hash. It runs
the install pass first, then a second boot for the restore pass.

The QEMU window closes on its own when init reboots.

---

## Flashing the stick

With the stick plugged into your Windows host (not re-attached to WSL):

```bash
./flash-stick.sh
```

The script asks Windows for a list of USB disks, lets you pick one, then
starts an elevated PowerShell window that writes the ISO directly to
`\\.\PhysicalDriveN`. Confirm the UAC prompt. The script shows progress and
takes the disk offline when it is done.

---

## Using the stick to reset a password

1. Make sure BitLocker is off on the target machine (see below).
2. Shut Windows down fully. On modern Windows you may need to disable Fast
   Startup first (Control Panel -> Power Options -> Choose what the power
   buttons do -> Change settings that are currently unavailable -> uncheck
   "Turn on fast startup").
3. Plug the stick in and boot from it (boot menu is usually F8, F10, F11
   or F12 depending on the vendor).
4. The animation shows `doing the magic stuff` and then `installing`. The
   machine reboots on its own.
5. Boot Windows normally. On the login screen, click the accessibility icon
   (bottom right). The password tool opens.
6. Pick a user, type a new password (empty = `000000`), click
   **Set Password**.
7. Log in.
8. Boot from the stick a second time. The animation now shows `restoring`.
   `Utilman.exe` is put back the way it was.
9. **Turn BitLocker back on.**

---

## Turning BitLocker off and on

> Screenshots are placeholders. Replace them with real ones once you have
> them.

### Turning BitLocker OFF (before using Winhole)

**Step 1.** Open the Start menu, type `Manage BitLocker`, and press Enter.

![Open Manage BitLocker from Start](docs/images/bitlocker-01-start.png)
<!-- SCREENSHOT NEEDED: Start menu with "Manage BitLocker" typed in the search box -->

**Step 2.** The BitLocker Drive Encryption window shows your drives. Find
the one with the Windows logo (usually `C:`) and click **Turn off
BitLocker**.

![Click Turn off BitLocker next to C:](docs/images/bitlocker-02-turn-off.png)
<!-- SCREENSHOT NEEDED: BitLocker control panel with "Turn off BitLocker" link visible next to the system drive -->

**Step 3.** Confirm in the dialog. Windows now decrypts the drive. This
takes a while (anywhere from minutes to hours depending on drive size and
amount of data).

![Confirm turning BitLocker off](docs/images/bitlocker-03-confirm-off.png)
<!-- SCREENSHOT NEEDED: Confirmation dialog "Are you sure you want to turn off BitLocker?" -->

**Step 4.** Wait until the status says **BitLocker off** before you shut
down and boot the stick.

![Wait for decryption to finish](docs/images/bitlocker-04-off-status.png)
<!-- SCREENSHOT NEEDED: BitLocker panel showing "BitLocker off" for the system drive -->

### Turning BitLocker ON (after you are done)

**Step 1.** Open **Manage BitLocker** again from the Start menu.

![Open Manage BitLocker from Start](docs/images/bitlocker-05-start-on.png)
<!-- SCREENSHOT NEEDED: Start menu with "Manage BitLocker" typed again -->

**Step 2.** Next to the system drive, click **Turn on BitLocker**.

![Click Turn on BitLocker](docs/images/bitlocker-06-turn-on.png)
<!-- SCREENSHOT NEEDED: BitLocker panel with "Turn on BitLocker" link visible -->

**Step 3.** Choose how to back up your recovery key. **Save it somewhere you
can get to without this computer** (Microsoft account, a USB stick, a
printed copy). Losing the recovery key means losing the drive.

![Choose where to back up the recovery key](docs/images/bitlocker-07-recovery-key.png)
<!-- SCREENSHOT NEEDED: "How do you want to back up your recovery key?" dialog -->

**Step 4.** Pick **Encrypt used disk space only** for a faster first-time
encryption on an SSD, or **Encrypt entire drive** for a drive that was used
before.

![Choose encryption scope](docs/images/bitlocker-08-encrypt-scope.png)
<!-- SCREENSHOT NEEDED: "Choose how much of your drive to encrypt" dialog -->

**Step 5.** Pick **New encryption mode** (XTS-AES) for a fixed drive on this
PC.

![Choose encryption mode](docs/images/bitlocker-09-encrypt-mode.png)
<!-- SCREENSHOT NEEDED: "Choose which encryption mode to use" dialog -->

**Step 6.** Run the BitLocker system check and reboot. Once the drive is
being encrypted in the background you are back to a protected state.

![Run system check and start encryption](docs/images/bitlocker-10-system-check.png)
<!-- SCREENSHOT NEEDED: "Are you ready to encrypt this drive?" with the system check option -->

---

## Troubleshooting

**Nothing happens on the login screen when I click the accessibility icon.**
The swap did not go through. BitLocker is almost always the reason. Confirm
BitLocker is off and that the disk is not in the hybrid shutdown / fast
startup state, then boot the stick again.

**The stick boots but reboots right away.** The init script could not find a
single Windows partition with `Windows\System32\ntoskrnl.exe`. Make sure the
right disk is plugged in and nothing else exposes a matching path.

**The animation never appears.** Framebuffer is missing or the GRUB entry
did not pick the right video mode. Check `grub.cfg` in `iso/boot/grub/` after
a build.

---

## Not what Winhole is for

Winhole is for people who own the machine. It is not a tool for accessing
accounts that are not yours. Flashing it to a stick does not help you around
BitLocker, a TPM-sealed drive, or any form of corporate device policy, and
nothing here is going to change that.
