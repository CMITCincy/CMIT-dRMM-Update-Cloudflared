<#
CMIT-dRMM-Update-Cloudflared.ps1
pellis@cmitsolutions.com
2025.12.11.001

Behavior: check version, run update, detect .exe.new, stop/swap/start, show version after.

Changelog: initial version

#>

# --- Helpers ---
function Resolve-CloudflaredPath {
  # Read ImagePath from the service registry key and extract the exe path
  $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\cloudflared'
  $img = (Get-ItemProperty -Path $svcKey -ErrorAction Stop).ImagePath

  if ($img -match '^"([^"]+\.exe)"') { return $Matches[1] }
  elseif ($img -match '^(?<path>[^\s]+\.exe)') { return $Matches['path'] }
  else { throw "Unable to parse ImagePath for service 'cloudflared': $img" }
}

function Get-CloudflaredVersion {
  param([string]$ExePath)
  try {
    $out = & $ExePath version 2>&1
    if (-not $out) { $out = (& $ExePath --version 2>&1) -or (& $ExePath version --short 2>&1) }
    return ($out | Out-String).Trim()
  } catch { return "Unknown (error: $($_.Exception.Message))" }
}

function Stop-CloudflaredService {
  try {
    $svc = Get-Service -Name cloudflared -ErrorAction Stop
    if ($svc.Status -ne 'Stopped') {
      Write-Host "Stopping service 'cloudflared'..."
      Stop-Service -Name cloudflared -Force -ErrorAction Stop
      (Get-Service -Name cloudflared).WaitForStatus('Stopped','00:00:20')
    }
    Write-Host "Service 'cloudflared' stopped."
  } catch {
    throw "Failed to stop service 'cloudflared': $($_.Exception.Message)"
  }
}

function Start-CloudflaredService {
  try {
    Write-Host "Starting service 'cloudflared'..."
    Start-Service -Name cloudflared -ErrorAction Stop
    (Get-Service -Name cloudflared).WaitForStatus('Running','00:00:20')
    Write-Host "Service 'cloudflared' running."
  } catch {
    throw "Failed to start service 'cloudflared': $($_.Exception.Message)"
  }
}

# --- Main ---
try {
  $exePath = Resolve-CloudflaredPath
  if (-not (Test-Path $exePath)) { throw "Binary not found: $exePath" }

  $folder  = Split-Path $exePath -Parent
  $exeName = Split-Path $exePath -Leaf
  $newPath = Join-Path $folder ($exeName + '.new')
  $oldPath = Join-Path $folder ($exeName + '.old')

  Write-Host "cloudflared executable: $exePath"
  $verBefore = Get-CloudflaredVersion -ExePath $exePath
  Write-Host "Version BEFORE: $verBefore"

  # Try update (support both syntaxes)
  Write-Host "Running 'cloudflared update'..."
  $updateOut = & $exePath update 2>&1
  if (-not $updateOut) {
    Write-Host "No output from 'cloudflared update'; trying '--update'..."
    $updateOut = & $exePath --update 2>&1
  }
  if ($updateOut) { Write-Host ($updateOut | Out-String) }

  Start-Sleep -Seconds 3

  $newExists = Test-Path $newPath
  $exeExists = Test-Path $exePath

  if ($newExists -and -not $exeExists) {
    # Primary exe missing but .new exists → promote .new and restart
    Write-Host "Detected '$exeName.new' with missing '$exeName'. Performing swap..."
    Stop-CloudflaredService
    if (Test-Path $oldPath) { Remove-Item $oldPath -Force -ErrorAction SilentlyContinue }
    Rename-Item -Path $newPath -NewName $exeName -ErrorAction Stop
    Start-CloudflaredService
  }
  elseif ($newExists) {
    # Both exist → enforce safe swap
    Write-Host "Detected '$exeName.new' while '$exeName' exists. Enforcing safe swap..."
    Stop-CloudflaredService
    Rename-Item -Path $exePath -NewName ($exeName + '.old') -ErrorAction SilentlyContinue
    Rename-Item -Path $newPath -NewName $exeName -ErrorAction Stop
    if (Test-Path $oldPath) { Remove-Item $oldPath -Force -ErrorAction SilentlyContinue }
    Start-CloudflaredService
  }
  else {
    # No .new artifact — ensure service is running
    $svc = Get-Service -Name cloudflared -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
      Write-Host "Service 'cloudflared' is not running; starting..."
      Start-CloudflaredService
    }
  }

  $verAfter = Get-CloudflaredVersion -ExePath $exePath
  Write-Host "Version AFTER:  $verAfter"
  Write-Host "Update workflow complete."

} catch {
  Write-Error "Update failed: $($_.Exception.Message)"
  exit 1
}
