# osed-mona3-setup

Offline deployment of [mona v3](https://github.com/corelan/mona3) + pykd-ext into a
Windows exploit-dev VM, with **Python 2.7.18 and Python 3.9.13 side by side**.

Everything is downloaded on the Linux host and handed to the VM over an RDP drive redirect, so the VM itself never needs internet access.

## Why both Pythons

mona v2 shipped `pykd.pyd` — a binary with the interpreter compiled in, so only Python 2.7 ever worked. 
mona v3 uses **pykd-ext**, a bootstrapper extension that loads whichever interpreter you ask for at runtime, and `mona.py` itself is 2/3-compatible.
One install, two interpreters:

```
!load pykd
!py -3.9 C:\Tools\mona3\mona.py
!py -2.7 C:\Tools\mona3\mona.py
```

## Layout

```
.
├── install-mona.sh      # run on Kali: stage the payload into a share folder
├── install-mona.ps1     # run in the VM (elevated): install everything
└── workspace/
    └── osed-workspace.WEW   # optional: your own WinDBG workspace
```

Drop your `.WEW` in `workspace/` and it gets installed automatically. 
Omit it and that step is skipped.

## Quick start

On Kali:

```bash
git clone https://github.com/<you>/osed-mona3-setup
cd osed-mona3-setup
./install-mona.sh
```

Then connect with the share redirected:

```bash
xfreerdp3 /u:Offsec /p:password /v:<vm-ip> /drive:mona-share,$HOME/mona-share +clipboard /dynamic-resolution
```

In the VM, from an **Administrator** terminal (works in both cmd.exe and PowerShell):

```
powershell -ExecutionPolicy Bypass -File \\tsclient\mona-share\install-mona.ps1
```

Takes a couple of minutes. It finishes by verifying `import pykd` and `import keystone` in every interpreter it installed.

## What gets installed

| Component | Version | Location |
|---|---|---|
| mona v3 (`mona.py`, `windbglib.py`) | `main` | `C:\Tools\mona3` (+ copies in the Debuggers folders) |
| Python 3.9.13 (32-bit) | 3.9.13 | `C:\Python39-32` |
| Python 2.7.18 (32-bit) | 2.7.18 | `C:\Python27` |
| pykd (pip wheel, per interpreter) | 0.3.4.15 | `<python>\Lib\site-packages\pykd` |
| keystone-engine (pip wheel) | 0.9.2 | `<python>\Lib\site-packages\keystone` |
| pykd-ext bootstrapper (`pykd.dll`) | 2.0.0.25 | `<Debuggers>\<arch>\winext` + `%LOCALAPPDATA%\DBG\EngineExtensions32` |
| `msdia140.dll` | from the pykd wheel | `Common Files\Microsoft Shared\VC`, registered |
| VC++ 2010 SP1 runtime (x86) | — | system |
| Workspace (`.WEW`) | yours | `C:\<name>.WEW` (override with `MONA_WEW`) |
| Launchers | — | `windbg-mona-py3.bat` / `-py2.bat` + desktop shortcuts |

Python 3.9 is used because PyPI publishes a matching `cp39-win32` pykd wheel, so the whole thing stays offline-installable, and because Corelan recommends 3.9 for mona v3 under WinDBG.

## Options

`install-mona.sh` (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `SHAREDIR` | `~/mona-share` | where the payload is staged |
| `SHARENAME` | `mona-share` | RDP drive name used in the printed commands |
| `INCLUDE_X64` | `0` | also stage 64-bit Python + wheels + x64 pykd-ext |
| `WEW_SRC` | auto | explicit path to a `.WEW` |
| `FORCE` | `0` | re-download everything |
| `RDP_USER` / `RDP_HOST` | `Offsec` / placeholder | only used in the printed `xfreerdp` line |

`install-mona.ps1` (environment variables, set before running):

| Variable | Default | Meaning |
|---|---|---|
| `MONA_SHARE` | `\\tsclient\mona-share` | payload location |
| `MONA_DIR` | `C:\Tools\mona3` | where `mona.py` lives |
| `MONA_WEW` | `C:\<staged name>` | where to install the workspace |
| `MONA_PY2_FIRST` | unset | put Python 2.7 ahead of 3.9 in `PATH` |

Re-running is safe: existing Pythons are detected and skipped, and anything it replaces (old `pykd.pyd`/`pykd.dll`, old `mona.py`, an existing `.WEW`) is backed up with a timestamp suffix first.

## Using it

The generated desktop shortcut runs:

```
windbg.exe -WF C:\osed-workspace.WEW -c "!load pykd; as !mona !py -3.9 C:\Tools\mona3\mona.py; !mona config -set workingfolder C:\Tools\mona3\workingfolders\%p"
```

Right-click it and **Pin to taskbar**. It already carries the "run as administrator" flag, which WinDBG needs to attach to processes.

`%p` expands to the debuggee's process name, so each target gets its own mona output folder under `C:\Tools\mona3\workingfolders`.

For WinDBGX, put this in *File > Settings > Debugging settings > Startup*:

```
!load pykd
as !mona !py -3.9 C:\Tools\mona3\mona.py
```

Note the explicit `-3.9`. Bare `!py` uses whichever interpreter pykd-ext has marked as default, which is ambiguous once two are installed.

## Troubleshooting

```
!pykd.info      # pykd-ext version + every Python it can see
```

- **Symbol / DIA complaints** — re-register the DIA dll:
  `regsvr32 "C:\Program Files (x86)\Common Files\Microsoft Shared\VC\msdia140.dll"`
  (check `C:\Program Files\...` too; the Windows Kits location varies by VM).
- **`python` resolves to the wrong version** — open a new terminal so the updated
  machine `PATH` is picked up. Interpreter choice inside WinDBG is controlled by
  `!py -<version>`, not by `PATH`.
- **Legacy mona v2 stopped working** — expected. pykd-ext 2.0.0.25 is
  incompatible with pykd 0.2.0.x. The old files are next to the new ones with a
  `.<timestamp>.bak` suffix.
- **64-bit assembly fails** — install `keystone-engine` for that interpreter;
  `windbglib.py` falls back to a small built-in opcode cache without it.

## Credits

All the real work is Corelan's:

- [corelan/mona3](https://github.com/corelan/mona3) — mona v3
- [corelan/CorelanTraining](https://github.com/corelan/CorelanTraining) —
  pykd-ext builds, runtimes, and the upstream `CorelanPyKDInstall.ps1` (use that
  one if your VM has internet)

These scripts are a repackaging for offline / RDP-share deployment, based on the
original mona v2 install scripts from
[epi052/osed-scripts](https://github.com/epi052/osed-scripts).
