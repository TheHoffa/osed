#!/usr/bin/env bash
#
# install-mona.sh - stage everything mona v3 needs for an OFFLINE install on a
#                   Windows VM, into a folder you redirect over RDP.
#
# Upstream: https://github.com/corelan/mona3
#           https://github.com/corelan/CorelanTraining   (pykd-ext, runtimes)
#
# What changed vs. the old (mona v2) version of this script:
#   - mona.py / windbglib.py now come from corelan/mona3 (Python 2 AND 3 capable)
#   - pykd is no longer a pykd.pyd dropped into winext. We now stage:
#       * pykd-ext 2.0.0.25  (pykd.dll - the WinDBG bootstrapper extension)
#       * pykd python wheels (one per interpreter: cp27-win32, cp39-win32)
#   - Python 2.7.18 AND Python 3.9.13 (32-bit) are staged, because pykd-ext
#     lets you pick the interpreter at runtime: !py -2.7 ... / !py -3.9 ...
#   - keystone-engine wheel is included (mona uses it for 64-bit assembly)
#   - VC++ 2010 SP1 x86 runtime replaces the old VC++ 2008 (msdia90) runtime;
#     the DIA dll that matters now is msdia140.dll, which ships in the wheel
#
# Usage:
#   ./install-mona.sh                 # stage x86 payload into ~/mona-share
#   INCLUDE_X64=1 ./install-mona.sh   # also stage 64-bit python + wheels
#   SHAREDIR=/tmp/mona ./install-mona.sh
#   FORCE=1 ./install-mona.sh         # re-download everything
#
set -uo pipefail

SHARENAME="${SHARENAME:-mona-share}"
SHAREDIR="${SHAREDIR:-$HOME/$SHARENAME}"
INCLUDE_X64="${INCLUDE_X64:-0}"
FORCE="${FORCE:-0}"
RDP_USER="${RDP_USER:-Offsec}"
RDP_HOST="${RDP_HOST:-<windows-vm-ip>}"
WEW_SRC="${WEW_SRC:-}"   # custom WinDBG workspace; auto-detected when empty

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE="\\\\tsclient\\$SHARENAME"

# versions (bump here, filenames below follow)
PYKD_VER="0.3.4.15"
PYKDEXT_VER="2.0.0.25"
PY2_VER="2.7.18"
PY3_VER="3.9.13"
KEYSTONE_VER="0.9.2"

MONA_RAW="https://raw.githubusercontent.com/corelan/mona3/main"
CT_RAW="https://github.com/corelan/CorelanTraining/raw/refs/heads/master"
PYPI="https://files.pythonhosted.org/packages"

# "filename|url" - filename is what install-mona.ps1 looks for, so don't rename
DOWNLOADS=(
    "mona.py|$MONA_RAW/mona.py"
    "windbglib.py|$MONA_RAW/windbglib.py"
    "python-${PY2_VER}.msi|https://www.python.org/ftp/python/${PY2_VER}/python-${PY2_VER}.msi"
    "python-${PY3_VER}.exe|https://www.python.org/ftp/python/${PY3_VER}/python-${PY3_VER}.exe"
    "pykd-${PYKD_VER}-cp27-none-win32.whl|$PYPI/f1/ff/8e1ec7634d26e06178820f2b4a0bd024f73de72b9ab9f2afdeae66665f1b/pykd-${PYKD_VER}-cp27-none-win32.whl"
    "pykd-${PYKD_VER}-cp39-none-win32.whl|$PYPI/67/f7/19b2380834b6b4312a89731b0f00c8185b7f1ac015f2947da2969de5b37d/pykd-${PYKD_VER}-cp39-none-win32.whl"
    "keystone_engine-${KEYSTONE_VER}-py2.py3-none-win32.whl|$PYPI/88/b9/a9d8b6837346b86bcdda56e5c3fe4ac51f98f4ed40bf71fb6bd8605516da/keystone_engine-${KEYSTONE_VER}-py2.py3-none-win32.whl"
    "pykd-ext-${PYKDEXT_VER}-x86.zip|$CT_RAW/pykd-ext/${PYKDEXT_VER}/x86.zip"
    "vc2010_runtime_redist_x86.exe|$CT_RAW/runtimes/vc2010_runtime_redist_x86.exe"
)

X64_DOWNLOADS=(
    "python-${PY2_VER}.amd64.msi|https://www.python.org/ftp/python/${PY2_VER}/python-${PY2_VER}.amd64.msi"
    "python-${PY3_VER}-amd64.exe|https://www.python.org/ftp/python/${PY3_VER}/python-${PY3_VER}-amd64.exe"
    "pykd-${PYKD_VER}-cp27-none-win_amd64.whl|$PYPI/c3/13/69e94fe16a43402d5fc0f5919b070a674fbb49aa14320a39075a048b339a/pykd-${PYKD_VER}-cp27-none-win_amd64.whl"
    "pykd-${PYKD_VER}-cp39-none-win_amd64.whl|$PYPI/12/2d/fabb94c8bdbfc1748da0f21867ed44eb12a6b016bfe87abe5872ba75d6a3/pykd-${PYKD_VER}-cp39-none-win_amd64.whl"
    "keystone_engine-${KEYSTONE_VER}-py2.py3-none-win_amd64.whl|$PYPI/a4/8d/58471cb026de45397b29ba4b37ae3e20b434fae14c4b92fd3e9771a7bac8/keystone_engine-${KEYSTONE_VER}-py2.py3-none-win_amd64.whl"
    "pykd-ext-${PYKDEXT_VER}-x64.zip|$CT_RAW/pykd-ext/${PYKDEXT_VER}/x64.zip"
)

# sha256 for the files published with hashes on PyPI (python.org / Corelan
# artifacts are not hash-checked here, they only get a sanity check)
declare -A SHA256=(
    ["pykd-${PYKD_VER}-cp27-none-win32.whl"]="5f790c51232e8d356a5d343298123d4f2a24a1bcfe53e4b3d1e8c46993ae2039"
    ["pykd-${PYKD_VER}-cp39-none-win32.whl"]="c0b688ddd62c9509efe13d2977967c1069a0aecbf10b1317886a8bb54cd415af"
    ["pykd-${PYKD_VER}-cp27-none-win_amd64.whl"]="9750ad5924fc49db97b9c778573e2a1169df174125ee1c8fe29ecbe915b72b2f"
    ["pykd-${PYKD_VER}-cp39-none-win_amd64.whl"]="7ba793faff3bc0082075f4f97c229b5c8bcecfb6c3e2895d30a8dbb2b7062040"
    ["keystone_engine-${KEYSTONE_VER}-py2.py3-none-win32.whl"]="9f81e480904a405ef008f1d9f0e4a05e37d2bd83c5218a27136e1a294b02c1f6"
    ["keystone_engine-${KEYSTONE_VER}-py2.py3-none-win_amd64.whl"]="c91db1ff16d9d094e00d1827107d1b4afd5e63ce19b491a0140e660635000e8b"
)

fail=0

say()  { echo -e "[+] $*"; }
note() { echo -e "[=] $*"; }
warn() { echo -e "[!] $*" >&2; }

verify() {
    # verify <path>: size, optional sha256, and "did we get an HTML error page"
    local path="$1" name="${1##*/}" size want got

    size=$(stat -c %s "$path" 2>/dev/null || echo 0)
    if [[ "$size" -lt 1024 ]]; then
        warn "$name is only ${size} bytes - download looks wrong"
        return 1
    fi

    if head -c 512 "$path" | grep -qiE '<!doctype html|<html'; then
        warn "$name contains HTML, not the real file (check the URL)"
        return 1
    fi

    want="${SHA256[$name]:-}"
    if [[ -n "$want" ]] && command -v sha256sum >/dev/null; then
        got=$(sha256sum "$path" | cut -d' ' -f1)
        if [[ "$got" != "$want" ]]; then
            warn "$name sha256 mismatch"
            warn "    expected $want"
            warn "    got      $got"
            return 1
        fi
    fi
    return 0
}

fetch() {
    local name="${1%%|*}"
    local url="${1#*|}"
    local dest="$SHAREDIR/$name"

    if [[ -s "$dest" && "$FORCE" != "1" ]] && verify "$dest" >/dev/null 2>&1; then
        note "already staged: $name"
        return 0
    fi

    note "downloading $name"
    if ! wget -q --show-progress --tries=3 --timeout=30 -O "$dest" "$url"; then
        warn "failed to download $url"
        rm -f "$dest"
        fail=1
        return 1
    fi

    if ! verify "$dest"; then
        fail=1
        return 1
    fi
}

mkdir -p "$SHAREDIR"
say "staging payload in $SHAREDIR"

for item in "${DOWNLOADS[@]}"; do
    fetch "$item"
done

if [[ "$INCLUDE_X64" == "1" ]]; then
    say "INCLUDE_X64=1 - also staging 64-bit components"
    for item in "${X64_DOWNLOADS[@]}"; do
        fetch "$item"
    done
fi

# your custom WinDBG workspace, if you keep one in the repo. Not downloadable,
# so it is copied from workspace/ (or next to this script, or $WEW_SRC).
stage_workspace() {
    local candidates=()

    shopt -s nullglob nocaseglob
    if [[ -n "$WEW_SRC" ]]; then
        candidates=("$WEW_SRC")
    else
        candidates=("$SCRIPT_DIR"/workspace/*.wew "$SCRIPT_DIR"/*.wew)
    fi
    shopt -u nullglob nocaseglob

    if [[ ${#candidates[@]} -eq 0 ]]; then
        note "no .WEW workspace found - skipping (optional)"
        return 0
    fi

    if [[ ! -f "${candidates[0]}" ]]; then
        warn "WEW_SRC=${candidates[0]} does not exist"
        fail=1
        return 1
    fi

    cp -f "${candidates[0]}" "$SHAREDIR/"
    note "staged workspace: $(basename "${candidates[0]}")"
    if [[ ${#candidates[@]} -gt 1 ]]; then
        warn "found ${#candidates[@]} .WEW files, staged only $(basename "${candidates[0]}")"
    fi
}

stage_workspace

# the PowerShell installer travels with this script
if [[ -f "$SCRIPT_DIR/install-mona.ps1" ]]; then
    cp -f "$SCRIPT_DIR/install-mona.ps1" "$SHAREDIR/"
    note "copied install-mona.ps1 from $SCRIPT_DIR"
else
    warn "install-mona.ps1 not found next to this script - put it in $SHAREDIR yourself"
    fail=1
fi

echo
say "staged files:"
ls -lh "$SHAREDIR"
echo

if [[ "$fail" != "0" ]]; then
    warn "one or more items failed - fix those before running the installer"
fi

cat <<EOF
[+] next steps

    1) start RDP with the share redirected:

       xfreerdp3 /u:$RDP_USER /v:$RDP_HOST /drive:$SHARENAME,$SHAREDIR +clipboard /dynamic-resolution
       (older client: xfreerdp /u:$RDP_USER /v:$RDP_HOST /drive:$SHARENAME,$SHAREDIR)

    2) in the VM, open an **Administrator** terminal and run:

       powershell -ExecutionPolicy Bypass -File $SHARE\\install-mona.ps1

       That works as-is from cmd.exe and from PowerShell, and -File parses the
       whole script at once. (The old pipe form still works but executes one
       top-level statement at a time:
        powershell -c "cat $SHARE\\install-mona.ps1 | powershell -")

    3) when it finishes, open WinDBG (x86) and check:

       !load pykd
       !pykd.info
       !py -3.9 C:\\Tools\\mona3\\mona.py
       !py -2.7 C:\\Tools\\mona3\\mona.py
EOF
