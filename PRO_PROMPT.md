# Pro Prompt — net-optimizer continuous-improvement loop

Paste this into any future Claude Code session in the `~/net-optimizer/` working dir to have Claude keep improving the optimizer **autonomously, with real-Windows validation** every iteration.

---

## The prompt

```
You are continuing work on the `net-optimizer` project — a single PowerShell
script (`Optimize-Internet.ps1`) that measures and improves a Windows PC's
internet connection. Your job is to deepen it iteratively, with each iteration
validated by GitHub Actions running on real Windows.

## Project facts (do not re-derive)
- Repo: github.com/khaledq84ever/net-optimizer (branch: main)
- Local path: /home/khaled/net-optimizer
- Entry script: Optimize-Internet.ps1 (~900 lines)
- CI: .github/workflows/test-windows.yml — runs on windows-latest, supports
  workflow_dispatch with modes: measure-only | report | apply | revert
- Memory: project-net-optimizer, project-net-optimizer-ci, reference-pwsh-linux

## Design principles (binding — never violate)
1. NO snake oil. Every change must reference a documented Windows mechanism
   with a measurable effect. If you can't cite WHY it helps, don't add it.
2. ALL changes back up the previous value before applying — extend
   Backup-Settings (the JSON written next to the script) every time.
3. ALL changes are revertible via -Revert. Extend the REVERT block in the same PR.
4. Apply mode auto-elevates to Admin; CI runners are already Admin so skip-logic works.
5. Skip cleanly when a feature isn't supported (Wi-Fi adapter without EEE,
   missing registry key, older Windows). Use `try`/`catch` + `Warn`,
   never crash the whole run.
6. Output stays terminal-readable: `Head` for sections, `Good`/`Warn`/`Bad`
   for status lines. The HTML report mirrors what the terminal shows.

## The continuous-improvement loop (per iteration)
Do this in order, then start over:

  a. Pick ONE new optimization or diagnostic from the "candidates" list below
     (or propose one with a documented rationale).
  b. Read the relevant section of Optimize-Internet.ps1 to find the right
     insertion point. Touch the FIVE points every new optimization needs:
       - Get-NetworkState         (read current value)
       - Backup-Settings          (snapshot to JSON)
       - The "Applying optimizations" block (apply with try/catch)
       - REVERT block             (undo from JSON)
       - Run-Diagnostics or report (surface the change to the user)
  c. Parse + lint locally first:
       /home/khaled/.pwsh/pwsh -NoProfile -c '[System.Management.Automation.Language.Parser]::ParseFile("Optimize-Internet.ps1",[ref]$null,[ref]$errors)|Out-Null; if($errors){$errors|%{$_};exit 1}; "Parse OK"'
     New warnings only fail CI if they're Errors — Warnings stay clean.
  d. Commit with a focused message. Push to main. CI auto-runs on push.
  e. Watch the CI run:
       gh run watch <id> --interval 15 --exit-status -R khaledq84ever/net-optimizer
  f. Read the run log AND download the artifact:
       gh run view <id> --log-failed   # if failed
       gh run download <id> -R khaledq84ever/net-optimizer
     Look at net-optimizer-*.log for the actual before/after numbers.
  g. If CI is red — fix root cause, push again. Do not skip steps to make
     it green; PS 7 has real parsing differences from 5.1.
  h. Once measure-only is green, trigger apply-mode and capture the
     before/after delta:
       gh workflow run test-windows.yml -R khaledq84ever/net-optimizer -f mode=apply
     Verify download/upload/DNS didn't regress. Anything worse than the
     prior baseline = revert your change unless the regression is below
     measurement noise (~3%).
  i. Report to the user: what was added, the before/after numbers, and
     which 5 points were touched. Then return to step (a).

## Candidates list (work through these — pick highest user value first)
- TCP RWIN (auto-window scaling level: per workload, not just "normal")
- TCP Timestamps off (small overhead reduction on long sessions)
- Network Connections Bandwidth Limit policy (`ResetReservedBandwidth`)
- IPv6 transition off (Teredo / 6to4 / ISATAP) when no IPv6 connectivity
- Wi-Fi roaming aggressiveness reduced for stationary PCs
- Set Wi-Fi to prefer 5 GHz over 2.4 GHz where dual-band is available
- Detect & disable LSO v2 only on adapters with known driver bugs
- Connection throttle in Windows Update Delivery Optimization upload (DONE)
- Defender real-time scan exclusion for known-safe download dirs (opt-in)
- Disable Windows Search indexing of cloud-sync folders during the run
- Detect MTU on Wi-Fi via packet probe, set if it differs from 1500
- Add per-resolver DNS-over-HTTPS test (Quad9 DoH, Cloudflare DoH)
- ARP/NDP cache flush
- WinHTTP proxy auto-detect timing (some PCs hang on WPAD)
- Per-NIC RxBuffers/TxBuffers raise when below safe defaults
- "Latency-sensitive vs throughput-sensitive" mode flag (Gaming flag does
  part of this — extend with Interrupt Moderation tradeoff)

## What NOT to add
- Anything from the "tweaker community" without a Microsoft/RFC citation.
- Settings that require a reboot to take effect (this is a one-shot tool).
- IRPStackSize, MaxFreeTcbs, the old Win-XP-era TcpAckFrequency global, etc —
  these don't apply to modern Windows.
- Process priority tweaks. Not a network problem.
- Anything that disables IPv6 globally (breaks modern apps).

## Stop conditions
- All candidates above are done OR a candidate would violate the design
  principles → stop and report to the user.
- Three iterations in a row produce no measurable improvement on the CI
  baseline → stop and ask the user what dimension they care about most
  (throughput, latency, jitter, reliability).
```

---

## Why this prompt works

- **Self-contained.** A fresh Claude session can resume the work without re-reading the whole thread.
- **Forces real-Windows validation.** Every change ships through CI on real Windows before it ships to users.
- **Five-point checklist** is the actual structure of the script — skipping any one of those points is the most common cause of broken `-Revert`.
- **Candidates list is curated, not infinite.** It encodes which directions are worth pursuing and which are folklore.
- **Stop conditions prevent rabbit holes.** Without them, Claude can keep adding micro-tweaks long past the point of diminishing returns.
