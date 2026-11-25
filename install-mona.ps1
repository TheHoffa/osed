# install-mona.ps1 - install mona v3 (https://github.com/corelan/mona3) with
#                     BOTH Python 2.7.18 and Python 3.9.13 (32-bit) available.
#
# Run from an ELEVATED prompt, with the payload staged by install-mona.sh.
# Preferred, straight off the share - -File parses the whole script at once, and
# this line is identical in cmd.exe and PowerShell:
#
#     powershell -ExecutionPolicy Bypass -File \\tsclient\mona-share\install-mona.ps1
#
# The old one-liner still works, but "powershell -" executes each top-level
# statement as it reads it, which is fragile around multi-line blocks:
#
#     powershell -c "cat \\tsclient\mona-share\install-mona.ps1 | powershell -"
#
# If you do want a local copy first, mind the shell:
#     PowerShell : copy \\tsclient\mona-share\install-mona.ps1 $env:USERPROFILE\Desktop\
#     cmd.exe    : copy \\tsclient\mona-share\install-mona.ps1 %USERPROFILE%\Desktop\
#
# Overrides (set before running, because piping into powershell can't take args):
#     $env:MONA_SHARE   = '\\tsclient\mona-share'   payload location
#     $env:MONA_DIR     = 'C:\Tools\mona3'          where mona.py lives
#     $env:MONA_PY2_FIRST = '1'                     put Python 2.7 first in PATH
#     $env:MONA_WEW     = 'C:\osed-workspace.WEW'   where to install the .WEW
#                                                   (default: C:\<staged name>)
#
# How this differs from the old mona v2 setup:
#   old: pykd.pyd (a Python-2.7-only binary) dropped into WinDBG's winext, so the
#        interpreter was baked in and only one Python could ever work.
#   new: pykd-ext (pykd.dll) is a bootstrapper. It loads whichever Python you ask
#        for at runtime, and the pykd module is installed per-interpreter as a
#        wheel. mona v3's mona.py runs on 2.7 and 3.x, so both work side by side:
#            !load pykd
#            !py -3.9 C:\Tools\mona3\mona.py
#            !py -2.7 C:\Tools\mona3\mona.py

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- settings --
$ShareRoot  = if ($env:MONA_SHARE) { $env:MONA_SHARE } else { '\\tsclient\mona-share' }
$InstallDir = "$env:USERPROFILE\Desktop\install-mona"
$MonaDir    = if ($env:MONA_DIR)   { $env:MONA_DIR }   else { 'C:\Tools\mona3' }
$Py2First   = ($env:MONA_PY2_FIRST -eq '1')
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'

# Python installs. A row is skipped when its installer is not in the payload,
# so the 64-bit rows only run when install-mona.sh was given INCLUDE_X64=1.
$PyTargets = @(
    [pscustomobject]@{
        Label = 'Python 3.9.13 (32-bit)'; Dir = 'C:\Python39-32'; Bitness = 'x86'
        Include = 'python-3.9*.exe'; Exclude = '*amd64*'; Type = 'exe'
        Pykd = 'pykd-*-cp39-none-win32.whl'; Keystone = 'keystone_engine-*-win32.whl'
        Selector = '-3.9'
    }
    [pscustomobject]@{
        Label = 'Python 2.7.18 (32-bit)'; Dir = 'C:\Python27'; Bitness = 'x86'
        Include = 'python-2.7*.msi'; Exclude = '*amd64*'; Type = 'msi'
        Pykd = 'pykd-*-cp27-none-win32.whl'; Keystone = 'keystone_engine-*-win32.whl'
        Selector = '-2.7'
    }
    [pscustomobject]@{
        Label = 'Python 3.9.13 (64-bit)'; Dir = 'C:\Python39-64'; Bitness = 'x64'
        Include = 'python-3.9*amd64*.exe'; Exclude = $null; Type = 'exe'
        Pykd = 'pykd-*-cp39-none-win_amd64.whl'; Keystone = 'keystone_engine-*-win_amd64.whl'
        Selector = '-3.9-64'
    }
    [pscustomobject]@{
        Label = 'Python 2.7.18 (64-bit)'; Dir = 'C:\Python27-64'; Bitness = 'x64'
        Include = 'python-2.7*amd64*.msi'; Exclude = $null; Type = 'msi'
        Pykd = 'pykd-*-cp27-none-win_amd64.whl'; Keystone = 'keystone_engine-*-win_amd64.whl'
        Selector = '-2.7-64'
    }
)

# --------------------------------------------------------------- functions --
function Write-Step    { param($m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Note    { param($m) Write-Host "[=] $m" }
function Write-Problem { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Payload {
    param([string]$Include, [string]$Exclude)
    $items = Get-ChildItem -Path $InstallDir -Filter $Include -File -ErrorAction SilentlyContinue
    if ($Exclude) { $items = $items | Where-Object { $_.Name -notlike $Exclude } }
    $items | Select-Object -First 1
}

function Expand-Zip {
    param([string]$ZipPath, [string]$Destination)
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function Invoke-Exe {
    param([string]$FilePath, [string[]]$Arguments, [string]$Label, [switch]$NonFatal)
    Write-Note "$Label"
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        $msg = "$Label exited with code $($p.ExitCode)"
        if ($NonFatal) { Write-Problem $msg } else { throw $msg }
    }
}

function Backup-File {
    param([string]$Path)
    if (Test-Path $Path) {
        Move-Item -Path $Path -Destination "$Path.$Stamp.bak" -Force
        Write-Note "backed up $Path -> $Path.$Stamp.bak"
    }
}

function Get-DebuggersRoot {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers",
        "$env:ProgramFiles\Windows Kits\10\Debuggers",
        "${env:ProgramFiles(x86)}\Windows Kits\8.1\Debuggers",
        "$env:ProgramFiles\Windows Kits\8.1\Debuggers"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'x86\windbg.exe'))) { return $c }
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Install-Wheel {
    param([string]$PythonExe, [string]$Wheel, [string]$Label)
    # pip writes deprecation notices to stderr; don't let that abort the script
    $ErrorActionPreference = 'Continue'
    & $PythonExe -m pip --version *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Note "bootstrapping pip for $Label"
        & $PythonExe -m ensurepip *> $null
    }
    Write-Note "installing $([System.IO.Path]::GetFileName($Wheel)) into $Label"
    & $PythonExe -m pip install --no-index --no-deps --force-reinstall `
        --disable-pip-version-check "$Wheel"
    if ($LASTEXITCODE -ne 0) { throw "pip failed for $Wheel ($Label)" }
}

function Test-PyModule {
    param([string]$PythonExe, [string]$Module, [string]$Label)
    $ErrorActionPreference = 'Continue'
    $out = & $PythonExe -c "import $Module; print($Module.__file__)" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Note "    $Label : import $Module OK" ; return $true }
    Write-Problem "    $Label : import $Module FAILED -> $out"
    return $false
}

function Register-Dll {
    param([string]$DllPath, [string]$Bitness)
    if (-not (Test-Path $DllPath)) { return $false }
    $regsvr = if ($Bitness -eq 'x64') { "$env:WINDIR\System32\regsvr32.exe" }
              else                    { "$env:WINDIR\SysWOW64\regsvr32.exe" }
    if (-not (Test-Path $regsvr)) { $regsvr = "$env:WINDIR\System32\regsvr32.exe" }
    Invoke-Exe -FilePath $regsvr -Arguments @('/s', "`"$DllPath`"") `
        -Label "registering $([System.IO.Path]::GetFileName($DllPath)) ($Bitness)" -NonFatal
    return $true
}

function Install-Workspace {
    # Installs a custom WinDBG workspace (.WEW) staged in the payload, and
    # returns where it landed (or $null when there isn't one).
    $wew = Get-ChildItem $InstallDir -Filter '*.wew' -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $wew) {
        Write-Note 'no .WEW workspace in the payload - skipping (it is optional)'
        return $null
    }
    $target = if ($env:MONA_WEW) { $env:MONA_WEW } else { "C:\$($wew.Name)" }
    Write-Step "installing WinDBG workspace to $target"
    # Split-Path on 'C:\foo.WEW' gives 'C:\', and New-Item -ItemType Directory
    # rejects a drive root - so only create the parent when it is missing
    $parent = Split-Path $target -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # WinDBG writes the workspace back on exit, so never clobber an existing one
    Backup-File $target
    Copy-Item $wew.FullName $target -Force
    return $target
}

function Set-MonaConfig {
    # Writes mona.ini the way mona itself does (key=value, # comments). mona.ini
    # lives in the folder that holds mona.py, so seeding it here means the
    # setting sticks regardless of how mona is launched - which matters because
    # "!mona config -set ..." cannot run on the same command line that defines
    # the !mona alias (WinDBG parses the whole line before the alias exists).
    param([string]$Ini, [hashtable]$Settings)

    $lines = @()
    if (Test-Path $Ini) {
        $lines = @(Get-Content $Ini)
    } else {
        $lines = @(
            '# -----------------------------------------------#',
            '# mona.py configuration file                      #',
            '# Corelan Consulting bv - https://www.corelan.be  #',
            '# -----------------------------------------------#'
        )
    }

    foreach ($key in @($Settings.Keys)) {
        $value = $Settings[$key]
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if (-not $line -or $line.TrimStart().StartsWith('#')) { continue }
            if (($line.Split('=', 2)[0]).Trim() -ieq $key) {
                $lines[$i] = "$key=$value"
                $found = $true
            }
        }
        if (-not $found) { $lines += "$key=$value" }
        Write-Note "    $key=$value"
    }

    Set-Content -Path $Ini -Value $lines -Encoding ASCII
    Write-Note "    written to $Ini"
}

function New-WinDbgShortcut {
    param([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkingDirectory)
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath         = $Target
    $lnk.Arguments          = $Arguments
    $lnk.WorkingDirectory   = $WorkingDirectory
    $lnk.IconLocation       = "$Target,0"
    $lnk.Description        = 'WinDBG with pykd-ext + mona v3'
    $lnk.Save()
    # flip the "run as administrator" bit in the .lnk header - WinDBG needs it
    # to attach to processes, and there is no COM property for this
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Write-Launchers {
    # One .bat per interpreter next to windbg.exe, plus a desktop shortcut you
    # can right-click > Pin to taskbar. Both carry the same -WF / -c payload.
    param($Installed, $DbgRoot, $Mona, $WorkFolder, $Wew)

    if (-not $DbgRoot) { Write-Note 'no WinDBG install - skipping launchers'; return }
    Write-Step 'writing WinDBG launchers (batch files + desktop shortcuts)'
    $desktop = [Environment]::GetFolderPath('Desktop')

    foreach ($t in $Installed) {
        $archDir = Join-Path $DbgRoot $t.Bitness
        if (-not (Test-Path $archDir)) { continue }
        $tag = if ($t.Selector -like '-2*') { 'py2' } else { 'py3' }

        # Deliberately just load + alias. The working folder comes from mona.ini,
        # because a "!mona ..." call here would not be alias-substituted yet.
        $cmd = "!load pykd; as !mona !py $($t.Selector) $Mona\mona.py"
        $wf = ''
        if ($Wew) { $wf = "-WF `"$Wew`" " }

        # in a .bat, %p must be written %%p or cmd.exe eats it before WinDBG sees it
        $batCmd = $cmd.Replace('%p', '%%p')
        $bat = Join-Path $archDir "windbg-mona-$tag.bat"
        $body = @"
@echo off
REM WinDBG ($($t.Bitness)) + pykd-ext + mona v3 on $($t.Label)
set ORIGPATH=%PATH%
set PYTHONHOME=$($t.Dir)
set PATH=%PYTHONHOME%;%PATH%
set PYTHONPATH=%PYTHONHOME%\Lib
windbg.exe -hd $($wf)-c "$batCmd" %*
set PATH=%ORIGPATH%
set PYTHONHOME=
set PYTHONPATH=
"@
        Set-Content -Path $bat -Value $body -Encoding ASCII
        Write-Note "    $bat"

        if ($desktop -and (Test-Path $desktop)) {
            $lnk = Join-Path $desktop "WinDBG $($t.Bitness) mona3 ($tag).lnk"
            New-WinDbgShortcut -Path $lnk `
                -Target (Join-Path $archDir 'windbg.exe') `
                -Arguments "$($wf)-c `"$cmd`"" `
                -WorkingDirectory $archDir
            Write-Note "    $lnk  (right-click > Pin to taskbar)"
        }
    }
}

function Show-Summary {
    # Everything here lives in a function on purpose: a function definition is a
    # single statement, so it survives being piped into "powershell -" intact.
    # Loose top-level statements after a multi-line block can get dropped there.
    param($Installed, $Mona, [bool]$Ok, $Wew, $WorkFolder)

    $def = $Installed | Where-Object { $_.Selector -like '-3*' } | Select-Object -First 1
    if (-not $def) { $def = $Installed[0] }

    Write-Host ''
    Write-Step 'done'
    Write-Host ''
    Write-Host 'Paths:' -ForegroundColor Cyan
    Write-Host "    mona.ini       $Mona\mona.ini"
    Write-Host "    mona output    $WorkFolder\<process name>   (created on first write)"
    if ($Wew) { Write-Host "    workspace      $Wew" }
    Write-Host ''
    Write-Host 'Pin the launcher: Desktop > "WinDBG x86 mona3 (py3)" > right-click > Pin to taskbar' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Run mona in WinDBG classic / WinDBGX:' -ForegroundColor Cyan
    Write-Host '    !load pykd'
    foreach ($t in $Installed) {
        Write-Host "    !py $($t.Selector) $Mona\mona.py            # $($t.Label)"
    }
    Write-Host ''
    Write-Host 'Make it an alias (or use the generated windbg-mona-py3.bat):' -ForegroundColor Cyan
    Write-Host "    as !mona !py $($def.Selector) $Mona\mona.py"
    Write-Host ''
    Write-Host 'WinDBGX: File > Settings > Debugging settings > Startup, paste:' -ForegroundColor Cyan
    Write-Host '    !load pykd'
    Write-Host "    as !mona !py $($def.Selector) $Mona\mona.py"
    Write-Host ''
    Write-Host 'If something misbehaves:' -ForegroundColor Cyan
    Write-Host '    !pykd.info                          # which pykd-ext + which pythons it sees'
    Write-Host '    !mona config -get workingfolder     # should echo the path above'
    Write-Host "    regsvr32 `"${env:ProgramFiles(x86)}\Common Files\Microsoft Shared\VC\msdia140.dll`""
    Write-Host '    open a NEW terminal so the updated PATH is picked up'
    if (-not $Ok) {
        Write-Problem 'at least one interpreter could not import pykd - check the output above'
    }
}

function Set-PathEntries {
    param([string[]]$Entries)
    $current = ([Environment]::GetEnvironmentVariable('Path','Machine') -split ';') |
               Where-Object { $_ -and $_.Trim() }
    $norm    = $Entries | ForEach-Object { $_.TrimEnd('\').ToLower() }
    $kept    = $current | Where-Object { $norm -notcontains $_.TrimEnd('\').ToLower() }
    $new     = (@($Entries) + @($kept)) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $new, 'Machine')
    $env:Path = $new
}

# ------------------------------------------------------------------- start --
if (-not (Test-Admin)) {
    throw 'This script must run from an elevated (Administrator) prompt.'
}

Write-Step "payload source: $ShareRoot"
if (-not (Test-Path $ShareRoot)) {
    throw "cannot reach $ShareRoot - is the RDP drive redirect active?"
}

Write-Step "copying payload to $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -Path (Join-Path $ShareRoot '*') -Destination $InstallDir -Recurse -Force

$dbgRoot = Get-DebuggersRoot
# NB: keep if/else on one line at top level - when this script is piped into
# "powershell -", each complete top-level statement runs as it is read, so an
# "else" starting its own line is parsed as a command and fails.
if ($dbgRoot) { Write-Step "found WinDBG (classic) at $dbgRoot" } else { Write-Problem 'WinDBG (classic) not found - pykd.dll will only be installed for WinDBGX' }

# -- 1. retire the legacy (mona v2 / pykd 0.2.x) bits ------------------------
Write-Step 'backing up legacy pykd / mona files'
if ($dbgRoot) {
    foreach ($arch in @('x86','x64')) {
        foreach ($leaf in @('winext\pykd.pyd', 'winext\pykd.dll', 'mona.py', 'windbglib.py')) {
            Backup-File (Join-Path $dbgRoot "$arch\$leaf")
        }
    }
}

# -- 2. VC++ 2010 SP1 x86 runtime (needed by pykd-ext / DIA) -----------------
$vc = Get-Payload -Include 'vc2010_runtime_redist_x86.exe'
if ($vc) {
    Write-Step 'installing VC++ 2010 SP1 redistributable (x86)'
    Invoke-Exe -FilePath $vc.FullName -Arguments @('/quiet','/norestart') `
        -Label 'vc2010_runtime_redist_x86.exe' -NonFatal
} else {
    Write-Problem 'vc2010_runtime_redist_x86.exe not in payload - skipping'
}

# -- 3. install the Python interpreters --------------------------------------
$installed = @()

foreach ($t in $PyTargets) {
    $installer = Get-Payload -Include $t.Include -Exclude $t.Exclude
    if (-not $installer) {
        Write-Note "skipping $($t.Label) - no installer in payload"
        continue
    }

    $pythonExe = Join-Path $t.Dir 'python.exe'

    if (Test-Path $pythonExe) {
        Write-Note "$($t.Label) already present at $($t.Dir)"
    }
    else {
        Write-Step "installing $($t.Label) to $($t.Dir)"
        if ($t.Type -eq 'msi') {
            Invoke-Exe -FilePath 'msiexec.exe' -Arguments @(
                '/i', "`"$($installer.FullName)`"", '/qn',
                'ALLUSERS=1', "TARGETDIR=`"$($t.Dir)`"", 'ADDLOCAL=ALL'
            ) -Label "msiexec $($installer.Name)"
        }
        else {
            Invoke-Exe -FilePath $installer.FullName -Arguments @(
                '/quiet', 'InstallAllUsers=1', "TargetDir=$($t.Dir)",
                'PrependPath=0', 'Include_launcher=1', 'Include_pip=1',
                'Include_test=0', 'AssociateFiles=0', 'Shortcuts=0'
            ) -Label $installer.Name
        }
    }

    if (-not (Test-Path $pythonExe)) {
        Write-Problem "$($t.Label) install did not produce $pythonExe - skipping its packages"
        continue
    }

    $wheel = Get-Payload -Include $t.Pykd
    if ($wheel) { Install-Wheel -PythonExe $pythonExe -Wheel $wheel.FullName -Label $t.Label }
    else { Write-Problem "no pykd wheel matching $($t.Pykd) - $($t.Label) will not work with mona" }

    $ks = Get-Payload -Include $t.Keystone
    if ($ks) { Install-Wheel -PythonExe $pythonExe -Wheel $ks.FullName -Label $t.Label }
    else { Write-Note "no keystone wheel for $($t.Label) - 64-bit assembly support will be limited" }

    $t | Add-Member -NotePropertyName Exe -NotePropertyValue $pythonExe -Force
    $installed += $t
}

if (-not $installed) { throw 'no Python interpreter was installed - nothing else to do' }

# -- 4. pykd-ext bootstrapper (pykd.dll) -------------------------------------
# WinDBG classic finds it in <Debuggers>\<arch>\winext, WinDBGX in
# %LOCALAPPDATA%\DBG\EngineExtensions(32). Install to both.
Write-Step 'installing pykd-ext bootstrapper (pykd.dll)'

$profileRoots = @()
$profileRoots += $env:LOCALAPPDATA
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    Where-Object { @('Public','Default','Default User','All Users') -notcontains $_.Name } |
    ForEach-Object { $profileRoots += (Join-Path $_.FullName 'AppData\Local') }
$profileRoots = $profileRoots | Where-Object { $_ -and (Test-Path (Split-Path $_ -Parent)) } |
                Select-Object -Unique

foreach ($arch in @('x86','x64')) {
    $zip = Get-Payload -Include "pykd-ext-*-$arch.zip"
    if (-not $zip) { Write-Note "no pykd-ext $arch zip in payload - skipping"; continue }

    $extract = Join-Path $InstallDir "pykd-ext-$arch"
    Expand-Zip -ZipPath $zip.FullName -Destination $extract
    $dll = Get-ChildItem $extract -Filter 'pykd.dll' -Recurse -File | Select-Object -First 1
    if (-not $dll) { Write-Problem "pykd.dll not found inside $($zip.Name)"; continue }

    $targets = @()
    if ($dbgRoot) { $targets += (Join-Path $dbgRoot "$arch\winext") }
    $engineLeaf = if ($arch -eq 'x86') { 'DBG\EngineExtensions32' } else { 'DBG\EngineExtensions' }
    foreach ($root in $profileRoots) { $targets += (Join-Path $root $engineLeaf) }

    foreach ($dest in $targets) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $destDll = Join-Path $dest 'pykd.dll'
        if ((Test-Path $destDll) -and ($dest -notlike "*winext")) { Backup-File $destDll }
        Copy-Item $dll.FullName $destDll -Force
        Write-Note "    $destDll"
    }
}

# -- 5. msdia140.dll (symbol / DIA support) ----------------------------------
# Ships inside the pykd wheel; replaces the old msdia90.dll from VC++ 2008.
Write-Step 'registering msdia140.dll'
foreach ($t in $installed) {
    $src = Get-ChildItem (Join-Path $t.Dir 'Lib\site-packages\pykd') -Filter 'msdia140.dll' `
               -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $src) { Write-Note "    no msdia140.dll under $($t.Dir) - skipping"; continue }

    $shared = if ($t.Bitness -eq 'x64') { "$env:ProgramFiles\Common Files\Microsoft Shared\VC" }
              else { "${env:ProgramFiles(x86)}\Common Files\Microsoft Shared\VC" }
    if (-not $shared) { $shared = "$env:ProgramFiles\Common Files\Microsoft Shared\VC" }

    New-Item -ItemType Directory -Path $shared -Force | Out-Null
    $dest = Join-Path $shared 'msdia140.dll'
    Copy-Item $src.FullName $dest -Force
    Register-Dll -DllPath $dest -Bitness $t.Bitness | Out-Null
}
# best effort, these help with older symbol formats if present
Register-Dll -DllPath "${env:ProgramFiles(x86)}\Windows Kits\10\App Certification Kit\msdia120.dll" -Bitness 'x86' | Out-Null
Register-Dll -DllPath "$env:ProgramFiles\Common Files\Microsoft Shared\VC\msdia100.dll" -Bitness 'x64' | Out-Null

# -- 6. mona v3 files --------------------------------------------------------
Write-Step "installing mona v3 to $MonaDir"
New-Item -ItemType Directory -Path $MonaDir -Force | Out-Null
foreach ($name in @('mona.py','windbglib.py')) {
    $f = Get-Payload -Include $name
    if (-not $f) { throw "$name is missing from the payload" }
    if ((Get-Content $f.FullName -TotalCount 5) -match '<!DOCTYPE|<html') {
        throw "$name looks like an HTML page, not Python source - re-download it"
    }
    Copy-Item $f.FullName (Join-Path $MonaDir $name) -Force
    Write-Note "    $MonaDir\$name"
    # convenience copies so '!py mona.py' also works from the debugger folders
    if ($dbgRoot) {
        foreach ($arch in @('x86','x64')) {
            $archDir = Join-Path $dbgRoot $arch
            if (Test-Path $archDir) { Copy-Item $f.FullName (Join-Path $archDir $name) -Force }
        }
    }
}

# -- 7. PATH -----------------------------------------------------------------
# pykd-ext picks the interpreter via !py -<ver>, so PATH order is only about
# what plain 'python' means in a shell. Python 3 first unless asked otherwise.
Write-Step 'updating machine PATH'
$ordered = if ($Py2First) {
    @($installed | Where-Object { $_.Selector -like '-2*' }) +
    @($installed | Where-Object { $_.Selector -like '-3*' })
} else {
    @($installed | Where-Object { $_.Selector -like '-3*' }) +
    @($installed | Where-Object { $_.Selector -like '-2*' })
}
$pathEntries = @()
foreach ($t in $ordered) { $pathEntries += $t.Dir; $pathEntries += (Join-Path $t.Dir 'Scripts') }
Set-PathEntries -Entries $pathEntries
Write-Note "    $($pathEntries -join ';')"

# -- 8. workspace, mona working folders, launchers ---------------------------
$workFolder = Join-Path $MonaDir 'workingfolders'
New-Item -ItemType Directory -Path $workFolder -Force | Out-Null
Write-Step 'configuring mona working folder'
Set-MonaConfig -Ini (Join-Path $MonaDir 'mona.ini') -Settings @{ workingfolder = "$workFolder\%p" }
$wewInstalled = Install-Workspace
Write-Launchers -Installed $installed -DbgRoot $dbgRoot -Mona $MonaDir -WorkFolder $workFolder -Wew $wewInstalled

# -- 9. verify ---------------------------------------------------------------
Write-Step 'verifying interpreters'
$ok = $true
foreach ($t in $installed) {
    Write-Note "$($t.Label) -> $($t.Exe)"
    if (-not (Test-PyModule -PythonExe $t.Exe -Module 'pykd' -Label $t.Label)) { $ok = $false }
    Test-PyModule -PythonExe $t.Exe -Module 'keystone' -Label $t.Label | Out-Null
}

# -- done --------------------------------------------------------------------
Show-Summary -Installed $installed -Mona $MonaDir -Ok $ok -Wew $wewInstalled -WorkFolder $workFolder
