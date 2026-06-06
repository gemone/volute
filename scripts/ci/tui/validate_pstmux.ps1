param(
  [string]$BinaryPath = ".\zig-out\bin\vx.exe",
  [string]$ArtifactDir = ".\.tmp\tui-result-windows"
)

$ErrorActionPreference = "Stop"

function Invoke-PsTmuxCliScenario {
  param(
    [string]$MuxCmd,
    [string]$SessionName,
    [string]$BinaryPath,
    [string]$TargetFile
  )

  & $MuxCmd "new-session" "-d" "-s" $SessionName "TERM=xterm-256color `"$BinaryPath`" `"$TargetFile`""
  Start-Sleep -Milliseconds 900

  $keys = @(
    @("send-keys","-t","$SessionName:0.0","g","g"),
    @("send-keys","-t","$SessionName:0.0","i","HEAD-"),
    @("send-keys","-t","$SessionName:0.0","C-["),
    @("send-keys","-t","$SessionName:0.0","j"),
    @("send-keys","-t","$SessionName:0.0","y"),
    @("send-keys","-t","$SessionName:0.0","p"),
    @("send-keys","-t","$SessionName:0.0","u"),
    @("send-keys","-t","$SessionName:0.0","U"),
    @("send-keys","-t","$SessionName:0.0","/","gamma","Enter"),
    @("send-keys","-t","$SessionName:0.0","x"),
    @("send-keys","-t","$SessionName:0.0","u"),
    @("send-keys","-t","$SessionName:0.0",":","wq","Enter")
  )

  foreach ($k in $keys) {
    & $MuxCmd @k
    Start-Sleep -Milliseconds 200
  }

  $exited = $false
  for ($i = 0; $i -lt 120; $i++) {
    & $MuxCmd "has-session" "-t" $SessionName *> $null
    if ($LASTEXITCODE -ne 0) {
      $exited = $true
      break
    }
    Start-Sleep -Milliseconds 100
  }
  if (-not $exited) {
    throw "Timed out waiting for pstmux session $SessionName to exit"
  }
}

if (-not (Test-Path -LiteralPath $BinaryPath)) {
  throw "vx binary not found: $BinaryPath"
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$expectedFile = Join-Path $root "scripts\ci\tui\expected_final.txt"
$workDir = Join-Path $env:RUNNER_TEMP ("vx-ci-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $workDir -Force
$targetFile = Join-Path $workDir "scenario.txt"
$sessionName = "vxci" + (Get-Random -Minimum 1000 -Maximum 9999)

@"
alpha
beta
gamma
"@ | Set-Content -Path $targetFile -NoNewline -Encoding UTF8

$muxCmd = $null
$muxCandidate = Get-Command pstmux -ErrorAction SilentlyContinue
if ($muxCandidate) {
  $muxCmd = $muxCandidate.Source
}

if (-not $muxCmd) {
  throw "pstmux command not found after installation; cannot run Windows multiplexer validation"
}

Invoke-PsTmuxCliScenario -MuxCmd $muxCmd -SessionName $sessionName -BinaryPath $BinaryPath -TargetFile $targetFile

$null = New-Item -ItemType Directory -Path $ArtifactDir -Force
$finalFile = Join-Path $ArtifactDir "final.txt"
Copy-Item -Path $targetFile -Destination $finalFile -Force

$hash = Get-FileHash -Algorithm SHA256 -Path $finalFile
"$($hash.Hash.ToLowerInvariant())  final.txt" | Set-Content -Path (Join-Path $ArtifactDir "final.sha256") -Encoding UTF8

$expected = (Get-Content -Raw -Path $expectedFile).Replace("`r`n","`n")
$actual = (Get-Content -Raw -Path $finalFile).Replace("`r`n","`n")
if ($expected -ne $actual) {
  Write-Error "Scenario output mismatch`n=== expected ===`n$expected`n=== actual ===`n$actual"
  exit 1
}

Write-Host "pstmux validation passed: $finalFile"
