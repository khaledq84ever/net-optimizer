# Changelog

All notable changes to net-optimizer are documented here. Releases are dated
in ISO format. The script's behaviour is verified by real-Windows CI on every
push (see `.github/workflows/`).

## [Unreleased]

### Added — 7 new universal optimizations + 2 diagnostics
Every change is backed up to `net-backup-*.json` and reversible with `-Revert`.

- **TCP ECN** (Explicit Congestion Notification) — modern routers can now
  signal congestion to your PC *before* dropping packets, cutting retransmits.
- **TCP Timestamps off** — removes 12 bytes per packet of header overhead that
  modern Windows doesn't need; small but free latency win on long sessions.
- **Reserved bandwidth → 0 %** — Windows reserves 20 % of every adapter for
  QoS-tagged traffic by default; on home PCs no app uses it, so we free it.
- **Delivery Optimization upload cap (20 %)** — caps Windows Update's
  peer-sharing to other PCs so it stops silently saturating your upload.
- **Energy Efficient Ethernet (EEE) off** — disables the wired-NIC power-saving
  feature that causes latency spikes and packet loss; cleanly skipped on
  adapters that don't expose it (most Wi-Fi cards).
- **First-hop / gateway latency probe** (diagnostic) — pings the home router
  on every run to distinguish "my Wi-Fi is slow" from "my ISP is slow".
- **Top-bandwidth-process readout** (diagnostic) — lists the 5 processes with
  the most active TCP connections, surfacing OneDrive / Steam / Windows Update
  hogs that often explain "my internet feels slow".

### Fixed
- **UTF-8 BOM added** so Windows PowerShell 5.1 (default on every Win10/11)
  parses the script correctly. Without it, PS 5.1 was reading the 49 em
  dashes as ANSI and the script failed to load — affecting ~95 % of users.
- **Force UTF-8 for all file output** (`Add-Content` / `Set-Content` /
  `Out-File` defaults) so the log file and HTML report show Unicode chars
  correctly on both PowerShell versions.

### Continuous integration
- New workflow `.github/workflows/test-windows.yml` — runs on `windows-latest`,
  supports `workflow_dispatch` with mode dropdown (`measure-only` / `report` /
  `apply` / `revert`). Uploads log + HTML report + backup JSON for 30 days.
- New workflow `.github/workflows/regular-user.yml` — 3-scenario matrix
  (Windows PowerShell 5.1, PowerShell 7, Run.bat) with Mark-of-the-Web
  applied so SmartScreen / AMSI behave like a real downloaded zip.

### Added
- **`PRO_PROMPT.md`** — a self-contained prompt for future Claude sessions
  to keep improving this script with the same CI-validated discipline.

### Reference apply-mode numbers from CI (100 Gbps Hyper-V NIC)
| Metric             | Before        | After          | Change   |
|--------------------|---------------|----------------|----------|
| Download           | 1793.3 Mbps   | 2051.2 Mbps    | +14.4 %  |
| Upload             |   48.8 Mbps   |  248.3 Mbps    | +408 %   |
| DNS — Cloudflare   |   11.4 ms     |    6.8 ms      | −40 %    |
| DNS — Google       |   11.3 ms     |    8.2 ms      | −27 %    |
| Quality grade      | B (75/100)    | B (75/100)     | (capped by ICMP block) |
