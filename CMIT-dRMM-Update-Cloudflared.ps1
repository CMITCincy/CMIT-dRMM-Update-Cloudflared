<#
CMIT-dRMM-Update-Cloudflared.ps1
pellis@cmitsolutions.com
2026.10.27.002

Behavior:
  verify native x64 -> confirm MSI-based install -> read installed version ->
  get latest release from GitHub -> download cloudflared-windows-amd64.msi ->
  verify (SHA256 when published + Authenticode) -> stop service -> msiexec upgrade ->
  start service -> verify running and on the new version.

Optional dRMM component variables (exposed as environment variables):
  ForceUpdate = true   Reinstall even if the installed version matches latest.

Exit codes: 0 = updated or already current, 1 = failure (dRMM marks job failed).
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Config ---
$ServiceName      = 'cloudflared'
$AssetName        = 'cloudflared-windows-amd64.msi'
$ApiUrl           = 'https://api.github.com/repos/cloudflare/cloudflared/releases/latest'
$DirectUrl        = "https://github.com/cloudflare/cloudflared/releases/latest/download/$AssetName"
$RequireSignature = $true    # Keep enabled: this blocks a tampered or unsigned installer from running as SYSTEM.
$ForceUpdate      = ($env:ForceUpdate -eq 'true')
$WorkDir          = Join-Path $env:TEMP ("cloudflared_update_{0}" -f ([guid]::NewGuid().ToString('N')))
$MsiLog           = Join-Path $env:ProgramData 'CMIT\Logs\cloudflared-msi-update.log'

# --- Helpers ---
function Test-IsX64 {
  # Native architecture from the registry (not fooled by WOW64 or ARM64 x64 emulation), cross-checked with WMI.
  $envKey     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  $nativeArch = (Get-ItemProperty -Path $envKey -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
  $cpuArch    = (Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1).Architecture   # 9 = x64, 12 = ARM64
  Write-Host "OS 64-bit: $([Environment]::Is64BitOperatingSystem) | Native arch: $nativeArch | CPU arch code: $cpuArch"
  return ([Environment]::Is64BitOperatingSystem -and $nativeArch -eq 'AMD64' -and $cpuArch -eq 9)
}

function Get-CloudflaredMsiEntry {
  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like 'cloudflared*' -and $_.WindowsInstaller -eq 1 } |
    Select-Object -First 1
}

function Get-ServiceExePath {
  $img = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName").ImagePath
  if ($img -match '^"([^"]+\.exe)"')        { return $Matches[1] }
  if ($img -match '^(?<path>[^\s]+\.exe)')  { return $Matches['path'] }
  throw "Unable to parse ImagePath for service '$ServiceName': $img"
}

function Get-CloudflaredVersion {
  param([Parameter(Mandatory=$true)][string]$Path)
  # Native stderr + ErrorActionPreference=Stop throws NativeCommandError on PS 5.1, so relax it locally.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try     { $out = (& $Path --version 2>&1 | Out-String) }
  finally { $ErrorActionPreference = $prev }
  if ($out -match '(\d{4}\.\d+\.\d+)') { return [version]$Matches[1] }
  throw "Could not parse cloudflared version from output: $out"
}

function Get-LatestReleaseInfo {
  # Returns @{ Version; Url; Sha256 }. Version/Sha256 are $null if the API is unavailable (e.g. rate limited).
  try {
    $headers = @{ 'User-Agent' = 'CMIT-dRMM-Cloudflared-Updater'; 'Accept' = 'application/vnd.github+json' }
    $rel   = Invoke-RestMethod -Uri $ApiUrl -Headers $headers -UseBasicParsing -TimeoutSec 30
    $asset = $rel.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset) { throw "Asset '$AssetName' not found in release $($rel.tag_name)" }

    $sha = $null
    if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
      $sha = $Matches[1]                                  # GitHub-computed asset digest
    } elseif ($rel.body -match "$([regex]::Escape($AssetName))\s*[:=]?\s*([0-9a-fA-F]{64})") {
      $sha = $Matches[1]                                  # Checksum list in release notes
    }
    return @{ Version = [version]($rel.tag_name.TrimStart('v')); Url = $asset.browser_download_url; Sha256 = $sha }
  } catch {
    Write-Warning "GitHub API lookup failed ($($_.Exception.Message)). Falling back to direct latest-download URL."
    return @{ Version = $null; Url = $DirectUrl; Sha256 = $null }
  }
}

function Test-Installer {
  param([Parameter(Mandatory=$true)][string]$Path, [string]$ExpectedSha256)

  if ((Get-Item $Path).Length -lt 1MB) { throw "Downloaded installer is suspiciously small; aborting." }

  if ($ExpectedSha256) {
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256.ToUpper()) { throw "SHA256 mismatch. Expected $ExpectedSha256, got $actual" }
    Write-Host "SHA256 verified: $actual"
  } else {
    Write-Warning "No published SHA256 available; relying on Authenticode signature."
  }

  $sig    = Get-AuthenticodeSignature -FilePath $Path
  $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '<none>' }
  Write-Host "Signature status: $($sig.Status) | Signer: $signer"
  if ($RequireSignature -and ($sig.Status -ne 'Valid' -or $signer -notmatch 'Cloudflare')) {
    throw "Authenticode signature check failed (Status: $($sig.Status), Signer: $signer)."
  }
}

function Stop-CloudflaredService {
  $svc = Get-Service -Name $ServiceName
  if ($svc.Status -ne 'Stopped') {
    Write-Host "Stopping service '$ServiceName'..."
    Stop-Service -Name $ServiceName -Force
    (Get-Service -Name $ServiceName).WaitForStatus('Stopped', '00:00:30')
  }
  # Make sure nothing still holds the exe open, or msiexec will schedule a reboot instead of replacing it.
  $p = Get-Process -Name cloudflared -ErrorAction SilentlyContinue
  if ($p) {
    Write-Host "Killing lingering cloudflared process (PID(s): $($p.Id -join ', '))..."
    $p | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }
  Write-Host "Service '$ServiceName' stopped."
}

function Start-CloudflaredService {
  Write-Host "Starting service '$ServiceName'..."
  Set-Service -Name $ServiceName -StartupType Automatic
  Start-Service -Name $ServiceName
  (Get-Service -Name $ServiceName).WaitForStatus('Running', '00:00:30')
  Start-Sleep -Seconds 5
  if ((Get-Service -Name $ServiceName).Status -ne 'Running') { throw "Service stopped shortly after starting." }
  Write-Host "Service '$ServiceName' running."
}

# --- Main ---
try {
  # 1. Architecture gate
  if (-not (Test-IsX64)) { throw "System is not native x64. This component only deploys the amd64 MSI." }

  # 2. Confirm install type and service
  $msiEntry = Get-CloudflaredMsiEntry
  if (-not $msiEntry) { throw "No MSI-based cloudflared install found. Skipping (non-MSI installs need a separate process)." }
  Write-Host "MSI install found: $($msiEntry.DisplayName) $($msiEntry.DisplayVersion)"

  if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    throw "Service '$ServiceName' is not registered. The tunnel must be set up with 'cloudflared service install' first."
  }
  $exePath = Get-ServiceExePath
  if (-not (Test-Path $exePath)) { throw "Service binary not found: $exePath" }

  # 3. Installed version (from the binary the service actually runs)
  $verBefore = Get-CloudflaredVersion -Path $exePath
  Write-Host "Installed version: $verBefore ($exePath)"

  # 4. Latest version
  $latest = Get-LatestReleaseInfo
  if ($latest.Version) {
    Write-Host "Latest release:    $($latest.Version)"
    if ($verBefore -ge $latest.Version -and -not $ForceUpdate) {
      Write-Host "Already up to date."
      if ((Get-Service -Name $ServiceName).Status -ne 'Running') { Start-CloudflaredService }
      exit 0
    }
  }

  # 5. Download and verify
  New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
  $msiPath = Join-Path $WorkDir $AssetName
  Write-Host "Downloading $($latest.Url)..."
  Invoke-WebRequest -Uri $latest.Url -OutFile $msiPath -UseBasicParsing -TimeoutSec 300
  Test-Installer -Path $msiPath -ExpectedSha256 $latest.Sha256

  # 6. Install
  New-Item -Path (Split-Path $MsiLog -Parent) -ItemType Directory -Force | Out-Null
  Stop-CloudflaredService
  Write-Host "Running msiexec upgrade (log: $MsiLog)..."
  $msiArgs = "/i `"$msiPath`" /qn /norestart /l*v `"$MsiLog`""
  $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
  switch ($proc.ExitCode) {
    0       { Write-Host "msiexec completed successfully." }
    3010    { Write-Warning "msiexec succeeded but reports a reboot is required (3010)." }
    1641    { Write-Warning "msiexec succeeded and initiated a reboot (1641)." }
    default { $installError = "msiexec failed with exit code $($proc.ExitCode). See $MsiLog" }
  }

  # 7. Always try to bring the service back, even if the install failed (MSI rolls itself back on failure)
  if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    throw "Service '$ServiceName' is missing after install. Tunnel must be re-registered manually. $installError"
  }
  Start-CloudflaredService
  if ($installError) { throw $installError }

  # 8. Verify
  $exePath  = Get-ServiceExePath
  $verAfter = Get-CloudflaredVersion -Path $exePath
  Write-Host "Version BEFORE: $verBefore"
  Write-Host "Version AFTER:  $verAfter"
  if ($latest.Version -and $verAfter -lt $latest.Version) {
    throw "Installed version $verAfter is still older than latest $($latest.Version). Service may point to a different binary than the MSI installed."
  }
  if ($verAfter -le $verBefore -and -not $ForceUpdate) {
    throw "Version did not change after install."
  }

  Write-Host "Update workflow complete."
  exit 0

} catch {
  Write-Host "ERROR: $($_.Exception.Message)"
  exit 1
} finally {
  if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}
