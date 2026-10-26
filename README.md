# AstroPrint

Prints Astrobit's shipping labels on any Windows label printer that understands ZPL
(Zebra, Xprinter and other thermal printers with ZPL emulation), connected by USB or over the
network: anything installed in Windows.

It answers on `127.0.0.1:9100` (HTTP) and `:9101` (HTTPS) with the same API as Zebra Browser
Print (`/default`, `/available`, `/write`, `/read`, `/config`, `/convert`), so the ERP prints
through it unchanged. Jobs go RAW to the Windows queue chosen in `config.json`; PDF labels arrive
as JPEG and are printed as a ZPL graphic. `GET https://127.0.0.1:9101/` returns
`{"status":"ok","agent":"AstroPrint","version":"…"}`, which tells AstroPrint apart from Browser
Print.

`/astroprint` is AstroPrint's own: `GET` lists Windows' printers (USB / network, and why one
wouldn't print right now), the chosen one and the label settings; `POST` changes them. The ERP's
Configuración › Impresora uses it to pick the printer and to fix a misaligned label without
touching the PC:

| `config.json` | ZPL added to every label | Range |
|---|---|---|
| `media`: `gap` / `continuous` / `mark` | `^MNY` / `^MNN` / `^MNM` | |
| `labelLengthDots` | `^LL`, when the label doesn't bring one | 160 – 3200 (150 mm = 1199) |
| `shiftDown` | `^LT` | -120 – 120 dots (8 per mm) |
| `shiftRight` | `^LS` (negated) | -120 – 120 dots |
| `darkness` | `^MD`, relative to the printer's | -15 – 15 |

Until version 7 it was called AstrobitPrint; the installer replaces it and keeps its
`config.json`.

## Download

- https://github.com/astrobitspa/astroprint/releases/latest/download/AstroPrint-Setup.exe
- https://github.com/astrobitspa/astroprint/releases/latest/download/AstroPrint.zip

Those links always serve the latest release. The installer runs `install.ps1 -Unattended`: no
console, and the printer is chosen afterwards in the ERP. The zip is the same scripts with
`install.bat`; its user guide (Spanish) is [AstroPrint/LEEME.txt](AstroPrint/LEEME.txt). Neither
is code-signed yet, so Windows warns that the publisher is unknown.

## What the installer changes on the PC

Runs elevated:

- copies the agent to `C:\ProgramData\AstroPrint` and writes `config.json`;
- creates a self-signed certificate for `localhost`/`127.0.0.1` on that PC, trusts it in
  `LocalMachine\Root` and binds it to port 9101 (`netsh http add sslcert`);
- registers the scheduled task `AstroPrint` (SYSTEM), started at boot and every minute as a
  watchdog;
- stops whatever holds ports 9100/9101 (`install.bat` asks first) and moves Browser Print out of
  startup, keeping a backup that the uninstaller restores;
- optionally, keeps the PC from sleeping while plugged in.

## Releasing

1. Change `$Version` in `AstroPrint/agent.ps1`.
2. Commit and push to `main`: the workflow builds `AstroPrint-Setup.exe`, downloadable from the
   run, to try before releasing.
3. Tag and push. `v8.1.0-rc1` publishes a pre-release, which the links above skip; `v8.1.0`
   publishes the release they serve.

The workflow checks that the tag matches `$Version`, zips the `AstroPrint` folder (CRLF line
endings, see `.gitattributes`) and publishes it with the installer.
