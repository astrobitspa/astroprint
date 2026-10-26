# AstroPrint

Prints Astrobit's shipping labels on any Windows label printer that understands ZPL
(Zebra, Xprinter and other thermal printers with ZPL emulation).

It answers on `127.0.0.1:9100` (HTTP) and `:9101` (HTTPS) with the same API as Zebra Browser
Print (`/default`, `/available`, `/write`, `/read`, `/config`, `/convert`), so the ERP prints
through it unchanged. Jobs go RAW to the Windows queue the installer asks for; PDF labels arrive
as JPEG and are printed as a ZPL graphic. `GET https://127.0.0.1:9101/` returns
`{"status":"ok","agent":"AstroPrint","version":"…"}`, which tells AstroPrint apart from Browser
Print.

Until version 7 it was called AstrobitPrint; the installer replaces it and keeps its
`config.json`.

## Download

https://github.com/astrobitspa/astroprint/releases/latest/download/AstroPrint.zip

That link always serves the latest release. The user guide (Spanish) is
[AstroPrint/LEEME.txt](AstroPrint/LEEME.txt).

## What the installer changes on the PC

Runs elevated (`install.bat` asks for it):

- copies the agent to `C:\ProgramData\AstroPrint` and writes `config.json`;
- creates a self-signed certificate for `localhost`/`127.0.0.1` on that PC, trusts it in
  `LocalMachine\Root` and binds it to port 9101 (`netsh http add sslcert`);
- registers the scheduled task `AstroPrint` (SYSTEM), started at boot and every minute as a
  watchdog;
- stops whatever holds ports 9100/9101 (asks first) and moves Browser Print out of startup,
  keeping a backup that `uninstall.bat` restores;
- optionally, keeps the PC from sleeping while plugged in.

## Releasing

1. Change `$Version` in `AstroPrint/agent.ps1`.
2. Commit, then tag and push: `git tag v8.0.1 && git push origin main v8.0.1`.

The `release` workflow checks that the tag matches `$Version`, zips the `AstroPrint` folder
(CRLF line endings, see `.gitattributes`) and publishes `AstroPrint.zip` as a release.
