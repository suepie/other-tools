<#
.SYNOPSIS
    複数サイトへ一定間隔で HTTP リクエストを行い、応答時間・ステータスコード・サイズを CSV に記録します。

.DESCRIPTION
    既定では 3 秒間隔で 60 秒間（= 20 サイクル）、対象ファイルに書かれた全 URL へ順にリクエストします。
    キャッシュの影響を避けるため、既定で以下を行います。
      - Cache-Control: no-cache / Pragma: no-cache ヘッダを付与
      - URL にキャッシュバスター（毎回異なるクエリパラメータ）を付与
      - Keep-Alive を無効化し、毎回新規接続で測定
    結果は 1 リクエスト 1 行の明細 CSV と、対象ごとの集計 CSV の 2 つを出力します。

.PARAMETER TargetFile
    測定対象を書いたファイル。既定はスクリプトと同じ場所の targets.txt。
    1 行 1 対象。「URL」または「表示名,URL」の形式。# 始まりと空行は無視されます。

.PARAMETER IntervalSeconds
    リクエスト間隔（秒）。既定 3。

.PARAMETER DurationSeconds
    測定の総時間（秒）。既定 60。

.PARAMETER OutputDirectory
    CSV の出力先ディレクトリ。既定はスクリプトと同じ場所の results。

.PARAMETER TimeoutSeconds
    1 リクエストのタイムアウト（秒）。既定 10。
    リクエスト間隔より長い値にすると、応答が遅いときに測定周期が乱れる点に注意してください。

.PARAMETER KeepAlive
    指定すると TCP 接続を再利用します（既定は毎回新規接続）。

.PARAMETER NoCacheBuster
    指定するとキャッシュバスターのクエリパラメータを付けません（ヘッダによる no-cache は維持）。

.EXAMPLE
    .\Measure-Network.ps1

.EXAMPLE
    .\Measure-Network.ps1 -TargetFile .\targets.txt -IntervalSeconds 5 -DurationSeconds 300
#>
[CmdletBinding()]
param(
    [string]$TargetFile,
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 3,
    [ValidateRange(1, 86400)]
    [int]$DurationSeconds = 60,
    [string]$OutputDirectory,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 10,
    [switch]$KeepAlive,
    [switch]$NoCacheBuster,
    [string]$UserAgent = 'NetworkMeasure/1.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Invoke-WebRequest の進捗表示は Windows PowerShell 5.1 で著しく遅いため抑止する
$ProgressPreference = 'SilentlyContinue'

# 古い環境でも TLS 1.2 以上で接続できるようにする
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "SecurityProtocol の設定をスキップしました: $($_.Exception.Message)"
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $TargetFile)      { $TargetFile      = Join-Path $scriptRoot 'targets.txt' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $scriptRoot 'results' }

# Excel でそのまま開けるよう BOM 付き UTF-8 で出力する
$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

function Read-Target {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "対象ファイルが見つかりません: $Path"
    }

    $targets = @()
    $lineNo = 0
    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $lineNo++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        # 「表示名,URL」形式なら分割し、なければ全体を URL として扱う
        if ($line -match '^(?<name>[^,]+),\s*(?<url>\S+)$') {
            $name = $Matches['name'].Trim()
            $url  = $Matches['url'].Trim()
        } else {
            $name = $null
            $url  = $line
        }

        if ($url -notmatch '^https?://') { $url = "https://$url" }

        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) {
            Write-Warning "$Path の $lineNo 行目を URL として解釈できないためスキップします: $raw"
            continue
        }
        if (-not $name) { $name = $uri.Host }

        $targets += [pscustomobject]@{
            Name = $name
            Url  = $uri.AbsoluteUri
        }
    }

    if ($targets.Count -eq 0) {
        throw "対象ファイルに有効な URL がありません: $Path"
    }
    return $targets
}

function New-CacheBustedUrl {
    param([string]$Url)

    $token = [Guid]::NewGuid().ToString('N')
    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    return "$Url$separator" + "_nc=$token"
}

function Get-ResponseSize {
    param($Response)

    # Content-Length ヘッダ → RawContentLength → 実データ長 の順に採用する
    try {
        $contentLength = $Response.Headers['Content-Length']
        if ($contentLength) { return [long]($contentLength | Select-Object -First 1) }
    } catch { }

    try {
        if ($Response.RawContentLength -ge 0) { return [long]$Response.RawContentLength }
    } catch { }

    try {
        if ($null -ne $Response.Content) {
            if ($Response.Content -is [byte[]]) { return [long]$Response.Content.Length }
            return [long][Text.Encoding]::UTF8.GetByteCount([string]$Response.Content)
        }
    } catch { }

    return [long]-1
}

function Invoke-Measurement {
    param(
        [int]$Cycle,
        [pscustomobject]$Target
    )

    $requestUrl = if ($NoCacheBuster) { $Target.Url } else { New-CacheBustedUrl -Url $Target.Url }

    $params = @{
        Uri             = $requestUrl
        Method          = 'GET'
        TimeoutSec      = $TimeoutSeconds
        UserAgent       = $UserAgent
        UseBasicParsing = $true
        Headers         = @{
            'Cache-Control' = 'no-cache, no-store, max-age=0'
            'Pragma'        = 'no-cache'
        }
    }
    if (-not $KeepAlive) { $params['DisableKeepAlive'] = $true }

    $status      = $null
    $statusText  = ''
    $sizeBytes   = [long]-1
    $contentType = ''
    $success     = $false
    $errorText   = ''

    # 時系列で並べたときにサンプル点が測定周期と揃うよう、開始時刻を記録する
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest @params
        $sw.Stop()

        $status     = [int]$response.StatusCode
        $statusText = [string]$response.StatusDescription
        $sizeBytes  = Get-ResponseSize -Response $response
        $success    = $true
        try {
            $ct = $response.Headers['Content-Type']
            if ($ct) { $contentType = ($ct | Select-Object -First 1) }
        } catch { }
    } catch {
        $sw.Stop()
        $ex = $_.Exception
        $errorText = $ex.Message

        # 4xx / 5xx は例外になるが、応答自体は返っているのでステータスを拾う
        $response = $null
        try { $response = $ex.Response } catch { }
        if ($response) {
            try { $status = [int]$response.StatusCode } catch { }
            try { $statusText = [string]$response.StatusDescription } catch { }
            try {
                $ct = $response.Headers['Content-Type']
                if ($ct) { $contentType = ($ct | Select-Object -First 1) }
            } catch { }
        }
    }

    $elapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    $throughput = if ($sizeBytes -gt 0 -and $elapsedMs -gt 0) {
        [math]::Round(($sizeBytes / 1024) / ($elapsedMs / 1000), 2)
    } else {
        $null
    }

    return [pscustomobject]@{
        Timestamp       = $timestamp
        Cycle           = $Cycle
        Name            = $Target.Name
        Url             = $Target.Url
        StatusCode      = $status
        StatusText      = $statusText
        ElapsedMs       = $elapsedMs
        SizeBytes       = $sizeBytes
        ThroughputKBps  = $throughput
        ContentType     = $contentType
        Success         = $success
        Error           = $errorText
    }
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $index = [math]::Ceiling($sorted.Count * $Percentile / 100) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return [math]::Round($sorted[$index], 1)
}

# ---- 実行 ----------------------------------------------------------------

$targets = Read-Target -Path $TargetFile

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$detailCsv   = Join-Path $OutputDirectory "network-$stamp.csv"
$summaryCsv  = Join-Path $OutputDirectory "network-$stamp-summary.csv"

$totalCycles = [math]::Max(1, [math]::Floor($DurationSeconds / $IntervalSeconds))

Write-Host "対象ファイル : $TargetFile"
Write-Host "対象サイト   : $($targets.Count) 件"
Write-Host "測定条件     : $IntervalSeconds 秒間隔 x $totalCycles 回（約 $DurationSeconds 秒）"
Write-Host "キャッシュ   : no-cache ヘッダ$(if (-not $NoCacheBuster) { ' + キャッシュバスター' })$(if (-not $KeepAlive) { ' + 接続再利用なし' })"
Write-Host "出力先       : $detailCsv"
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]
$startTime = Get-Date

for ($cycle = 1; $cycle -le $totalCycles; $cycle++) {
    # 実行時間のずれが蓄積しないよう、開始時刻からの絶対時刻で次サイクルを決める
    $scheduled = $startTime.AddSeconds($IntervalSeconds * ($cycle - 1))
    $wait = ($scheduled - (Get-Date)).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }

    foreach ($target in $targets) {
        $result = Invoke-Measurement -Cycle $cycle -Target $target
        $results.Add($result) | Out-Null

        # 途中で中断しても結果が残るよう 1 行ずつ追記する
        $result | Export-Csv -LiteralPath $detailCsv -NoTypeInformation -Encoding $csvEncoding -Append

        $statusLabel = if ($null -ne $result.StatusCode) { $result.StatusCode } else { 'ERR' }
        $line = '[{0,3}/{1}] {2,-24} {3,4}  {4,8} ms  {5,10} bytes' -f `
            $cycle, $totalCycles, $result.Name, $statusLabel, $result.ElapsedMs, $result.SizeBytes
        if ($result.Success) {
            Write-Host $line
        } else {
            Write-Host "$line  $($result.Error)" -ForegroundColor Yellow
        }
    }
}

# ---- 集計 ----------------------------------------------------------------

$summary = foreach ($group in ($results | Group-Object -Property Name)) {
    $ok = @($group.Group | Where-Object { $_.Success })
    $times = @($ok | ForEach-Object { [double]$_.ElapsedMs })
    $sizes = @($ok | Where-Object { $_.SizeBytes -gt 0 } | ForEach-Object { [double]$_.SizeBytes })

    [pscustomobject]@{
        Name         = $group.Name
        Url          = $group.Group[0].Url
        Requests     = $group.Count
        SuccessCount = $ok.Count
        ErrorCount   = $group.Count - $ok.Count
        SuccessRate  = [math]::Round(100 * $ok.Count / $group.Count, 1)
        AvgMs        = if ($times.Count) { [math]::Round(($times | Measure-Object -Average).Average, 1) } else { $null }
        MinMs        = if ($times.Count) { [math]::Round(($times | Measure-Object -Minimum).Minimum, 1) } else { $null }
        MaxMs        = if ($times.Count) { [math]::Round(($times | Measure-Object -Maximum).Maximum, 1) } else { $null }
        MedianMs     = Get-Percentile -Values $times -Percentile 50
        P95Ms        = Get-Percentile -Values $times -Percentile 95
        AvgSizeBytes = if ($sizes.Count) { [math]::Round(($sizes | Measure-Object -Average).Average, 0) } else { $null }
    }
}

$summary | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding $csvEncoding

Write-Host ''
Write-Host '===== 集計 ====='
$summary | Format-Table Name, Requests, SuccessCount, ErrorCount, AvgMs, MedianMs, MinMs, MaxMs, P95Ms, AvgSizeBytes -AutoSize
Write-Host "明細 CSV : $detailCsv"
Write-Host "集計 CSV : $summaryCsv"
