# Internet Optimizer (Windows)

A safe PowerShell script that **measures** your connection and applies real,
proven speed/stability tweaks — then shows you the before/after.

> It can't make your internet faster than your ISP plan. What it does is remove
> the things that keep Windows *below* that ceiling: slow DNS, Windows' built-in
> network throttle, Wi‑Fi/NIC power-saving, and poor TCP settings.

## What it changes (only with `-Apply`)
1. **Fastest DNS** — tests Cloudflare / Google / Quad9 / OpenDNS / your current one, picks the fastest, sets it.
2. **Removes Windows' network throttle** (`NetworkThrottlingIndex`).
3. **TCP autotuning + RSS** so big downloads ramp to full speed.
4. **Stops the adapter power-saving** (a top cause of Wi‑Fi slow-downs and drops).
5. **High-performance power plan.**
6. **Optimal MTU** (only if it detects a clearly better value).
7. **(optional) `-Gaming`** — lowers latency by disabling Nagle's algorithm.

Everything it touches is **backed up first** to `net-backup-*.json`, and you can
undo it all with one command.

## Easiest way: double-click `Run.bat`

1. Copy **both** `Run.bat` and `Optimize-Internet.ps1` into the **same folder** on your Windows PC.
2. **Double-click `Run.bat`.** Click **Yes** on the Administrator prompt.
3. Pick from the menu:
   ```
     [1]  Measure only       (changes nothing)
     [2]  Optimize speed
     [3]  Optimize + Gaming
     [4]  Undo / Revert
     [5]  Exit
   ```
That's it — no typing commands. (The manual command-line way is below if you prefer it.)

---

## Manual way (PowerShell)

1. Copy `Optimize-Internet.ps1` to your **Windows PC** (USB, download, OneDrive — anything).
2. Right‑click the **Start button → "Terminal (Admin)"** or **"Windows PowerShell (Admin)"**.
3. `cd` to the folder, e.g.:
   ```powershell
   cd C:\Users\YOU\Downloads
   ```
4. **First, just measure (changes nothing):**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Optimize-Internet.ps1
   ```
5. **Apply the optimizations:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Optimize-Internet.ps1 -Apply
   ```
   (add `-Gaming` on the end if you want lower latency for games/voice)

6. **Undo everything, anytime:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Optimize-Internet.ps1 -Revert
   ```

> The script auto-elevates to Administrator (you'll see a UAC prompt — click Yes).
> The `-ExecutionPolicy Bypass` part is just so Windows lets the script run; it
> doesn't change any system policy permanently.

## After applying
A **reboot** helps the TCP/MTU changes fully take effect. If anything ever feels
worse, run `-Revert` and reboot — you're back to exactly how you started.

## Is it safe?
- Measure-only by default; **nothing changes** unless you pass `-Apply`.
- Every changed setting is saved to a backup file before the change.
- `-Revert` restores that backup.
- No third-party downloads, no "boosters", no registry voodoo — only documented
  Windows networking settings.
