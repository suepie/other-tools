<#
.SYNOPSIS
    ブラウザからエクスポートした HAR ファイルを解析し、リクエストごとの所要時間を CSV に集計します。

.DESCRIPTION
    API キーを払い出せない環境で、ChatGPT などを「ブラウザで手動操作したときの実測値」を残すためのツールです。
    自動操作は一切行わず、DevTools が記録した HAR を後から読むだけなので、対象サービスの利用規約に触れません。

    HAR の timings をそのまま列に落とすので、次のように読めます。
      WaitMs    : リクエスト送信からレスポンス先頭が返るまで ＝ ストリーミング応答では実質 TTFT
      ReceiveMs : レスポンス本体の受信にかかった時間 ＝ ストリーミング応答では実質「生成にかかった時間」
      TotalMs   : そのリクエスト全体（HAR の time）

.PARAMETER Path
    HAR ファイル、またはそれを含むディレクトリ。複数指定できます。既定はカレントディレクトリの *.har。

.PARAMETER UrlFilter
    対象 URL を絞り込む正規表現。既定はチャット系のストリーミングエンドポイント。

.PARAMETER AllRequests
    指定すると UrlFilter を無視して HAR 内の全リクエストを対象にします。

.PARAMETER Discover
    探索モード。どの URL を測ればよいか分からないときに使います。
    絞り込みをせずに全リクエストを読み、ホスト別の集計・ストリーミング応答・
    時間のかかった POST を表示して終了します（集計は行いません）。
    ここで見つけた URL を -UrlFilter に渡して本測定します。

.PARAMETER Label
    出力に付ける任意のラベル（「昼」「社内LAN」など、条件を後から見分けるため）。

.PARAMETER OutputDirectory
    CSV の出力先。既定はスクリプトと同じ場所の results。

.EXAMPLE
    .\Measure-FromHar.ps1 .\chatgpt.har

.EXAMPLE
    .\Measure-FromHar.ps1 .\captures\ -Label '社内LAN 昼'

.EXAMPLE
    # どの URL がチャット本体か分からないとき（まずこれを実行する）
    .\Measure-FromHar.ps1 .\m365.har -Discover

.EXAMPLE
    # 探索で見つけた URL を指定して本測定
    .\Measure-FromHar.ps1 .\captures\ -UrlFilter 'substrate\.office\.com.*chat'

.EXAMPLE
    # 全リクエストを対象に、ページ読み込み全体を見る
    .\Measure-FromHar.ps1 .\chatgpt.har -AllRequests
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path,
    [string]$UrlFilter = '(backend-api/.*conversation|/api/(chat|conversation)|/v1/(chat/)?completions|/v1/messages|/conversation\b)',
    [switch]$AllRequests,
    [switch]$Discover,
    [string]$Label = '',
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Path)            { $Path            = @((Get-Location).Path) }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $scriptRoot 'results' }

$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

function Get-Prop {
    <#
        JSON 由来の PSCustomObject から、存在しないプロパティでも安全に値を取り出す。
    #>
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Match($Name).Count -eq 0) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function ConvertTo-Millisecond {
    <#
        HAR の timings は「計測不能」を -1 で表すので、その場合は空欄にする。
    #>
    param($Value)

    if ($null -eq $Value) { return $null }
    $d = [double]$Value
    if ($d -lt 0) { return $null }
    return [math]::Round($d, 1)
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)

    if ($Values.Count -eq 0) { return $null }
    # 要素が 1 つだと Sort-Object はスカラーを返す。StrictMode 下では
    # スカラーの .Count 参照が例外になるため、必ず配列に包む
    $sorted = @($Values | Sort-Object)
    $index = [math]::Ceiling($sorted.Count * $Percentile / 100) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return [math]::Round($sorted[$index], 1)
}

function Show-Candidate {
    <#
        どの URL がチャット本体なのか分からないときに、当たりを付けるための表示。
        ストリーミング応答は「POST」「長時間」「event-stream か json」という特徴が出ます。
    #>
    param([object[]]$Rows)

    $short = {
        param([string]$u)
        if ($u.Length -gt 90) { return $u.Substring(0, 90) + '…' }
        return $u
    }

    Write-Host ''
    Write-Host '===== ホスト別のリクエスト数と最長時間 ====='
    $Rows | Group-Object -Property Host | Sort-Object Count -Descending | Select-Object -First 15 |
        ForEach-Object {
            $times = @($_.Group | Where-Object { $null -ne $_.TotalMs } | ForEach-Object { [double]$_.TotalMs })
            [pscustomobject]@{
                Host       = $_.Name
                Requests   = $_.Count
                MaxTotalMs = if ($times.Count) { [math]::Round(($times | Measure-Object -Maximum).Maximum, 1) } else { $null }
            }
        } | Format-Table -AutoSize

    $sse = @($Rows | Where-Object { $_.MimeType -match 'event-stream' })
    Write-Host "===== ストリーミング応答（event-stream）: $($sse.Count) 件 ====="
    if ($sse.Count) {
        $sse | Sort-Object { [double]($_.TotalMs) } -Descending | Select-Object -First 10 |
            ForEach-Object {
                [pscustomobject]@{
                    TotalMs = $_.TotalMs
                    WaitMs  = $_.WaitMs
                    Method  = $_.Method
                    Url     = & $short $_.Url
                }
            } | Format-Table -AutoSize
    } else {
        Write-Host '  なし（M365 のように WebSocket や通常の JSON 応答を使う実装もあります）'
        Write-Host ''
    }

    Write-Host '===== 時間のかかった POST 上位20（チャット本体の最有力候補） ====='
    $slow = @($Rows | Where-Object { $_.Method -eq 'POST' -and $null -ne $_.TotalMs })
    if ($slow.Count) {
        $slow | Sort-Object { [double]($_.TotalMs) } -Descending | Select-Object -First 20 |
            ForEach-Object {
                [pscustomobject]@{
                    TotalMs  = $_.TotalMs
                    WaitMs   = $_.WaitMs
                    Status   = $_.StatusCode
                    MimeType = $_.MimeType
                    Url      = & $short $_.Url
                }
            } | Format-Table -AutoSize
    } else {
        Write-Host '  POST がありません'
        Write-Host ''
    }

    Write-Host '目星が付いたら、その URL に当たる正規表現を -UrlFilter に渡して測定してください。例:'
    Write-Host '  .\Measure-FromHar.ps1 .\captures\ -UrlFilter ''substrate\.office\.com.*chat'''
}

function Resolve-HarFile {
    param([string[]]$InputPath)

    $files = @()
    foreach ($p in $InputPath) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Warning "見つからないためスキップします: $p"
            continue
        }
        $item = Get-Item -LiteralPath $p
        if ($item.PSIsContainer) {
            $files += @(Get-ChildItem -LiteralPath $item.FullName -Filter '*.har' -File | Sort-Object Name)
        } else {
            $files += $item
        }
    }
    return $files
}

function Read-HarEntry {
    param([IO.FileInfo]$File)

    $raw = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    try {
        $har = $raw | ConvertFrom-Json
    } catch {
        throw "HAR の JSON を解釈できません ($($File.Name)): $($_.Exception.Message)"
    }

    $log = Get-Prop $har 'log'
    $entries = Get-Prop $log 'entries'
    if (-not $entries) { return @() }

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($entry in @($entries)) {
        $request  = Get-Prop $entry 'request'
        $response = Get-Prop $entry 'response'
        $timings  = Get-Prop $entry 'timings'
        $content  = Get-Prop $response 'content'

        $url = [string](Get-Prop $request 'url' '')
        if (-not $url) { continue }
        if (-not $AllRequests -and -not $Discover -and $url -notmatch $UrlFilter) { continue }

        $uri = $null
        [void][Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)

        # startedDateTime は ISO 8601（オフセット付き）。ローカル時刻に直して並べやすくする
        $startedAt = ''
        $startedRaw = Get-Prop $entry 'startedDateTime'
        if ($startedRaw) {
            try {
                $startedAt = ([DateTimeOffset]::Parse([string]$startedRaw)).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
            } catch {
                $startedAt = [string]$startedRaw
            }
        }

        $rows.Add([pscustomobject]@{
            SourceFile    = $File.Name
            Label         = $Label
            StartedAt     = $startedAt
            Method        = [string](Get-Prop $request 'method' '')
            Host          = if ($uri) { $uri.Host } else { '' }
            UrlPath       = if ($uri) { $uri.AbsolutePath } else { $url }
            StatusCode    = Get-Prop $response 'status'
            MimeType      = [string](Get-Prop $content 'mimeType' '')
            BlockedMs     = ConvertTo-Millisecond (Get-Prop $timings 'blocked')
            DnsMs         = ConvertTo-Millisecond (Get-Prop $timings 'dns')
            ConnectMs     = ConvertTo-Millisecond (Get-Prop $timings 'connect')
            SslMs         = ConvertTo-Millisecond (Get-Prop $timings 'ssl')
            SendMs        = ConvertTo-Millisecond (Get-Prop $timings 'send')
            WaitMs        = ConvertTo-Millisecond (Get-Prop $timings 'wait')
            ReceiveMs     = ConvertTo-Millisecond (Get-Prop $timings 'receive')
            TotalMs       = ConvertTo-Millisecond (Get-Prop $entry 'time')
            ContentBytes  = Get-Prop $content 'size'
            TransferBytes = Get-Prop $response '_transferSize'
            Url           = $url
        }) | Out-Null
    }

    return $rows
}

# ---- 実行 ----------------------------------------------------------------

$files = @(Resolve-HarFile -InputPath $Path)
if ($files.Count -eq 0) {
    throw "HAR ファイルが見つかりません: $($Path -join ', ')"
}

Write-Host "対象 HAR : $($files.Count) 件"
if ($Label) { Write-Host "ラベル   : $Label" }
if ($Discover) {
    Write-Host "モード   : 探索（絞り込みなし。候補を表示して終了します）"
} elseif ($AllRequests) {
    Write-Host "絞り込み : なし（全リクエスト）"
} else {
    Write-Host "絞り込み : $UrlFilter"
}
Write-Host ''

$rows = New-Object System.Collections.Generic.List[object]
foreach ($file in $files) {
    $parsed = @(Read-HarEntry -File $file)
    foreach ($row in $parsed) { $rows.Add($row) | Out-Null }
    Write-Host ("{0,-40} {1,4} 件" -f $file.Name, $parsed.Count)
}

if ($rows.Count -eq 0) {
    Write-Warning '条件に一致するリクエストがありませんでした。-Discover でどの URL が記録されているか確認してください。'
    return
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$detailCsv  = Join-Path $OutputDirectory "har-$stamp.csv"
$summaryCsv = Join-Path $OutputDirectory "har-$stamp-summary.csv"

$rows | Export-Csv -LiteralPath $detailCsv -NoTypeInformation -Encoding $csvEncoding

# ---- 探索モード ----------------------------------------------------------
# どの URL を測ればよいか分からないとき用。候補を出して終わる。

if ($Discover) {
    Show-Candidate -Rows $rows.ToArray()
    Write-Host ''
    Write-Host "全リクエストの明細 CSV : $detailCsv"
    return
}

# ---- 集計 ----------------------------------------------------------------

$summary = foreach ($group in ($rows | Group-Object -Property { "$($_.Host)$($_.UrlPath)" })) {
    $waits    = @($group.Group | Where-Object { $null -ne $_.WaitMs }    | ForEach-Object { [double]$_.WaitMs })
    $receives = @($group.Group | Where-Object { $null -ne $_.ReceiveMs } | ForEach-Object { [double]$_.ReceiveMs })
    $totals   = @($group.Group | Where-Object { $null -ne $_.TotalMs }   | ForEach-Object { [double]$_.TotalMs })

    [pscustomobject]@{
        Target        = $group.Name
        Label         = $Label
        Requests      = $group.Count
        AvgWaitMs     = if ($waits.Count)    { [math]::Round(($waits    | Measure-Object -Average).Average, 1) } else { $null }
        MedianWaitMs  = Get-Percentile -Values $waits -Percentile 50
        AvgReceiveMs  = if ($receives.Count) { [math]::Round(($receives | Measure-Object -Average).Average, 1) } else { $null }
        AvgTotalMs    = if ($totals.Count)   { [math]::Round(($totals   | Measure-Object -Average).Average, 1) } else { $null }
        MedianTotalMs = Get-Percentile -Values $totals -Percentile 50
        MinTotalMs    = if ($totals.Count)   { [math]::Round(($totals   | Measure-Object -Minimum).Minimum, 1) } else { $null }
        MaxTotalMs    = if ($totals.Count)   { [math]::Round(($totals   | Measure-Object -Maximum).Maximum, 1) } else { $null }
        P95TotalMs    = Get-Percentile -Values $totals -Percentile 95
    }
}

$summary = @($summary | Sort-Object -Property Requests -Descending)
$summary | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding $csvEncoding

Write-Host ''
Write-Host "===== 集計（$($rows.Count) リクエスト） ====="
$summary | Format-Table Target, Requests, AvgWaitMs, MedianWaitMs, AvgReceiveMs, AvgTotalMs, MedianTotalMs, P95TotalMs -AutoSize
Write-Host "明細 CSV : $detailCsv"
Write-Host "集計 CSV : $summaryCsv"
