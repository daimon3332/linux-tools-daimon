param(
    [Parameter(Mandatory = $true)][string]$Control,
    [Parameter(Mandatory = $true)][string]$Token,
    [ValidateRange(1, 20)][int]$MaxGB = 20
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$iperf = $env:DAIMON_IPERF3
if (-not $iperf) { $iperf = (Get-Command iperf3 -ErrorAction SilentlyContinue).Source }
if (-not $iperf) {
    $iperf = Read-Host 'iperf3.exe full path'
    if (-not (Test-Path -LiteralPath $iperf)) { throw 'iperf3.exe was not found' }
}
if (-not (Test-Path -LiteralPath $iperf)) { throw 'iperf3 executable was not found' }

$base = $Control.TrimEnd('/')
$tokenQuery = [Uri]::EscapeDataString($Token)
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$http = New-Object System.Net.Http.HttpClient($handler)
$lastId = -1
$totalBytes = [long]0
$deadline = (Get-Date).AddMinutes(35)
$completed = $false
$process = $null
try {
  while ((Get-Date) -lt $deadline) {
    $stage = $http.GetStringAsync("$base/stage?token=$tokenQuery").GetAwaiter().GetResult() | ConvertFrom-Json
    if ($stage.state -eq 'done') { Write-Host $stage.message; $completed = $true; return }
    if ($stage.state -eq 'error') { throw $stage.message }
    if ($stage.state -ne 'ready' -or [int]$stage.id -le $lastId) {
        Start-Sleep -Milliseconds 700
        continue
    }

    $family = [int]$stage.family
    $server = [string]$stage.host
    $port = [int]$stage.port
    $duration = [int]$stage.duration
    $omit = [int]$stage.omit
    $address = $null
    if (-not [Net.IPAddress]::TryParse($server, [ref]$address) -or $family -notin @(4, 6) -or
        $port -lt 1 -or $port -gt 65535 -or $duration -lt 1 -or $duration -gt 60 -or $omit -lt 0 -or $omit -gt 10) {
        throw 'Invalid benchmark stage'
    }
    Write-Host ("Round {0} ({1}): IPv{2} {3}:{4}" -f $stage.id, $stage.message, $family, $server, $port)
    $attempt = 0
    do {
        $attempt++
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $iperf
        $info.Arguments = "-c $server -p $port -$family -R -P 1 -t $duration -O $omit -i 1 -J"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        $null = $process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $roundDeadline = (Get-Date).AddSeconds($duration + $omit + 35)
        while (-not $process.HasExited) {
            if ((Get-Date) -ge $roundDeadline) {
                $process.Kill(); $process.WaitForExit()
                throw 'iperf3 connection or measurement timed out'
            }
            Start-Sleep -Milliseconds 200
        }
        $raw = $outputTask.GetAwaiter().GetResult()
        $stderr = $errorTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
        $process.Dispose(); $process = $null
        if ($exitCode -eq 0) { break }
        if ($attempt -ge 3) { throw "iperf3 failed after $attempt attempts: $raw $stderr" }
        Start-Sleep -Seconds 2
    } while ($true)

    $measurement = $raw | ConvertFrom-Json
    $received = $measurement.end.sum_received
    if (-not $received -or [double]$received.bits_per_second -le 0 -or [long]$received.bytes -le 0 -or
        [double]$received.seconds -lt $duration * 0.9) {
        throw "Round $($stage.id) has no valid receiver throughput"
    }
    $roundBytes = [long](($measurement.intervals | ForEach-Object { $_.sum.bytes } | Measure-Object -Sum).Sum)
    $totalBytes += [Math]::Max($roundBytes, [long]$received.bytes)
    $budget = [Math]::Min([long]$MaxGB * 1000000000, [long]$stage.budget_bytes)
    if ($totalBytes -gt $budget - 536870912) {
        throw "Traffic budget safety threshold reached: $MaxGB GB"
    }

    $sender = $measurement.end.sum_sent
    $result = @{
        id = [int]$stage.id
        family = $family
        receiver_mbps = [Math]::Round([double]$received.bits_per_second / 1000000, 2)
        bytes = [long]$received.bytes
        retrans = if ($sender.retransmits) { [int]$sender.retransmits } else { 0 }
        seconds = [double]$received.seconds
    }
    $json = $result | ConvertTo-Json -Compress
    $body = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    $response = $http.PostAsync("$base/result?token=$tokenQuery", $body).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null
    $response.Dispose()
    $body.Dispose()
    Write-Host ("  receiver: {0} Mbps, retrans: {1}, received: {2:N2} GB / {3} GB" -f $result.receiver_mbps, $result.retrans, ($totalBytes / 1000000000), $MaxGB)
    $lastId = [int]$stage.id
  }
  throw 'Benchmark session timed out'
} catch {
  try {
    $abortJson = @{ reason = $_.Exception.Message } | ConvertTo-Json -Compress
    $abortBody = New-Object System.Net.Http.StringContent($abortJson, [Text.Encoding]::UTF8, 'application/json')
    $null = $http.PostAsync("$base/abort?token=$tokenQuery", $abortBody).GetAwaiter().GetResult()
    $abortBody.Dispose()
  } catch { }
  throw
} finally {
    if ($process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    if (-not $completed) {
        try {
            $cancel = New-Object System.Net.Http.StringContent('{"reason":"client stopped"}', [Text.Encoding]::UTF8, 'application/json')
            $null = $http.PostAsync("$base/abort?token=$tokenQuery", $cancel).GetAwaiter().GetResult()
            $cancel.Dispose()
        } catch { }
    }
  $http.Dispose()
  $handler.Dispose()
}
