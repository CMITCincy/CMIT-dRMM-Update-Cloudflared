<#
CMIT-dRMM-Update-Cloudflared.ps1
pellis@cmitsolutions.com
2025.12.11.002

Behavior: check version, run update, detect .exe.new, stop/swap/start, show version after.

Changelog: fixing stuff

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

  # Version BEFORE
  $verBefore = & $exePath version
  Write-Host "Version BEFORE: $verBefore"

  # Try update
  Write-Host "Running 'cloudflared update'..."
  & $exePath update 2>$nul

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


  # Version AFTER
  $verAfter = & $exePath version
  Write-Host "Version AFTER:  $verAfter"
  Write-Host "Update workflow complete."

} catch {
  Write-Error "Update failed: $($_.Exception.Message)"
  #exit 1
}
