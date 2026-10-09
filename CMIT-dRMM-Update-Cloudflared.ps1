<#
CMIT-dRMM-Update-Cloudflared.ps1
pellis@cmitsolutions.com
2025.12.11.003

Behavior: version → update → detect .exe.new → stop/swap/start (with lock-safe retries) → version.
#>

# --- Helpers ---
function Resolve-CloudflaredPath {
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

    # Extra: ensure no lingering process keeps the file locked
    $p = Get-Process -Name cloudflared -ErrorAction SilentlyContinue
    if ($p) {
      Write-Host "Killing lingering cloudflared process (PID(s): $($p.Id -join ', '))..."
      $p | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 500
    }
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

# Robust rename/move with retries to handle transient locks
function Move-WithRetry {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Destination
  )
  $attempts = 0
  $maxAttempts = 10       # total ~5s (10 * 500ms)
  $delayMs = 500

  while ($attempts -lt $maxAttempts) {
    try {
      Move-Item -Path $Path -Destination $Destination -Force -ErrorAction Stop
      return $true
    } catch {
      $attempts++
      Start-Sleep -Milliseconds $delayMs
      if ($attempts -ge $maxAttempts) {
        throw "Move/Rename failed from '$Path' to '$Destination': $($_.Exception.Message)"
      }
    }
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

  # Update (suppress harmless stderr to avoid NativeCommandError in RMM)
  Write-Host "Running 'cloudflared update'..."
  & $exePath update 2>$null

  Start-Sleep -Seconds 8  # allow updater/batch to finish writing .new

  $newExists = Test-Path $newPath
  $exeExists = Test-Path $exePath

  if ($newExists -and -not $exeExists) {
    Write-Host "Detected '$exeName.new' with missing '$exeName'. Performing swap..."
    Stop-CloudflaredService

    if (Test-Path $oldPath) {
      Remove-Item $oldPath -Force -ErrorAction SilentlyContinue
    }

    # Promote .new -> .exe with retries
    Move-WithRetry -Path $newPath -Destination $exePath

    Start-CloudflaredService
  }
  elseif ($newExists) {
    Write-Host "Detected '$exeName.new' while '$exeName' exists. Enforcing safe swap..."
    Stop-CloudflaredService

    # Rename existing exe -> .old (retry)
    if (Test-Path $exePath) {
      Move-WithRetry -Path $exePath -Destination $oldPath
    }

    # Promote .new -> .exe (retry)
    Move-WithRetry -Path $newPath -Destination $exePath

    # Cleanup .old if present (optional)
    if (Test-Path $oldPath) {
      Remove-Item $oldPath -Force -ErrorAction SilentlyContinue
    }

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
  # Consider uncommenting exit 1 if you want RMM to mark the task failed:
  # exit 1
}
