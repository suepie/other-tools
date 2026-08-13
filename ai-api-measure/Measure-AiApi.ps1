<#
.SYNOPSIS
    AI API（Claude / Messages API ほか）へ決まった短いプロンプトを投げ、応答時間とトークン数を CSV に記録します。

.DESCRIPTION
    設定ファイル（JSON）に列挙したエンドポイントへ、一定間隔で同じプロンプトを送信します。
    ストリーミング（SSE）で受信するため、以下を分けて計測できます。
      - TTFB   : リクエスト送信からレスポンスヘッダ受信まで
      - TTFT   : 最初のトークン（最初の content delta）が届くまで ＝ 体感の待ち時間
      - Total  : ストリーム完了まで
    あわせて入出力トークン数と、出力トークン毎秒（TTFT 以降の生成速度）を記録します。

    対応プロバイダ:
      anthropic         : Claude API（/v1/messages、SSE）
      openai-compatible : OpenAI 互換の /chat/completions（Azure OpenAI・ローカル LLM など）

.PARAMETER ConfigFile
    エンドポイント定義の JSON。既定はスクリプトと同じ場所の endpoints.json。

.PARAMETER IntervalSeconds
    リクエスト間隔（秒）。既定 10。AI API は 1 リクエストに数秒かかるため、短くしすぎると測定周期が乱れます。

.PARAMETER DurationSeconds
    測定の総時間（秒）。既定 60。

.PARAMETER OutputDirectory
    CSV の出力先。既定はスクリプトと同じ場所の results。

.PARAMETER TimeoutSeconds
    1 リクエストのタイムアウト（秒）。既定 120。

.PARAMETER Only
    設定ファイルのうち、指定した名前のエンドポイントだけを対象にします（複数指定可）。

.PARAMETER NoCacheBuster
    指定するとプロンプト末尾のランダムな識別子を付けません。

.EXAMPLE
    $env:ANTHROPIC_API_KEY = 'sk-ant-...'
    .\Measure-AiApi.ps1

.EXAMPLE
    .\Measure-AiApi.ps1 -IntervalSeconds 30 -DurationSeconds 600 -Only 'Claude Opus 5'
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 10,
    [ValidateRange(1, 86400)]
    [int]$DurationSeconds = 60,
    [string]$OutputDirectory,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 120,
    [string[]]$Only,
    [switch]$NoCacheBuster
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 では System.Net.Http が既定で読み込まれていない
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "SecurityProtocol の設定をスキップしました: $($_.Exception.Message)"
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigFile)      { $ConfigFile      = Join-Path $scriptRoot 'endpoints.json' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $scriptRoot 'results' }

$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

function Get-ConfigValue {
    <#
        JSON 由来の PSCustomObject から、存在しないプロパティでも安全に値を取り出す。
    #>
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Match($Name).Count -eq 0) { return $Default }

    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    if ($value -is [string] -and $value.Trim() -eq '') { return $Default }
    return $value
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)

    if ($Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $index = [math]::Ceiling($sorted.Count * $Percentile / 100) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return [math]::Round($sorted[$index], 1)
}

function Read-EndpointConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "設定ファイルが見つかりません: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try {
        $config = $raw | ConvertFrom-Json
    } catch {
        throw "設定ファイルの JSON を解釈できません ($Path): $($_.Exception.Message)"
    }

    $endpoints = Get-ConfigValue $config 'endpoints'
    if (-not $endpoints) {
        throw "設定ファイルに endpoints がありません: $Path"
    }

    return [pscustomobject]@{
        Prompt    = [string](Get-ConfigValue $config 'prompt' 'Reply with the single word OK.')
        MaxTokens = [int](Get-ConfigValue $config 'maxTokens' 64)
        Endpoints = @($endpoints)
    }
}

function New-RequestBody {
    <#
        プロバイダごとのリクエストボディを組み立てる。ストリーミングは常に有効。
    #>
    param($Endpoint, [string]$Prompt, [int]$MaxTokens)

    $provider = [string](Get-ConfigValue $Endpoint 'provider' 'anthropic')
    $model    = [string](Get-ConfigValue $Endpoint 'model')
    if (-not $model) { throw "エンドポイント '$(Get-ConfigValue $Endpoint 'name' '(no name)')' に model がありません" }

    switch ($provider) {
        'anthropic' {
            $body = [ordered]@{
                model      = $model
                max_tokens = $MaxTokens
                stream     = $true
                messages   = @(@{ role = 'user'; content = $Prompt })
            }

            # effort は output_config の中。未対応モデルに送るとエラーになるため、指定時のみ付与する
            $effort = Get-ConfigValue $Endpoint 'effort'
            if ($effort) { $body['output_config'] = @{ effort = [string]$effort } }

            # thinking: disabled / adaptive / none（none は送信しない）
            $thinking = [string](Get-ConfigValue $Endpoint 'thinking' 'none')
            if ($thinking -ne 'none') { $body['thinking'] = @{ type = $thinking } }

            return $body
        }
        'openai-compatible' {
            $maxTokensField = [string](Get-ConfigValue $Endpoint 'maxTokensField' 'max_tokens')
            $body = [ordered]@{
                model          = $model
                stream         = $true
                stream_options = @{ include_usage = $true }
                messages       = @(@{ role = 'user'; content = $Prompt })
            }
            $body[$maxTokensField] = $MaxTokens
            return $body
        }
        default {
            throw "未対応の provider です: $provider"
        }
    }
}

function Set-RequestHeader {
    param($Request, $Endpoint, [string]$ApiKey)

    $provider = [string](Get-ConfigValue $Endpoint 'provider' 'anthropic')

    switch ($provider) {
        'anthropic' {
            $Request.Headers.Add('x-api-key', $ApiKey)
            $Request.Headers.Add('anthropic-version', [string](Get-ConfigValue $Endpoint 'anthropicVersion' '2023-06-01'))
            $betas = Get-ConfigValue $Endpoint 'betas'
            if ($betas) { $Request.Headers.Add('anthropic-beta', (@($betas) -join ',')) }
        }
        'openai-compatible' {
            # Azure OpenAI は api-key ヘッダなので、設定で切り替えられるようにする
            $scheme = [string](Get-ConfigValue $Endpoint 'authHeader' 'bearer')
            if ($scheme -eq 'api-key') {
                $Request.Headers.Add('api-key', $ApiKey)
            } else {
                $Request.Headers.Add('Authorization', "Bearer $ApiKey")
            }
        }
    }

    $extra = Get-ConfigValue $Endpoint 'headers'
    if ($extra) {
        foreach ($p in $extra.PSObject.Properties) {
            $Request.Headers.Add($p.Name, [string]$p.Value)
        }
    }
}

function Invoke-AiMeasurement {
    param(
        [int]$Cycle,
        $Endpoint,
        [string]$Prompt,
        [int]$MaxTokens
    )

    $name     = [string](Get-ConfigValue $Endpoint 'name' (Get-ConfigValue $Endpoint 'model' 'unnamed'))
    $provider = [string](Get-ConfigValue $Endpoint 'provider' 'anthropic')
    $url      = [string](Get-ConfigValue $Endpoint 'url')
    $keyEnv   = [string](Get-ConfigValue $Endpoint 'apiKeyEnv')

    $result = [ordered]@{
        Timestamp          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        Cycle              = $Cycle
        Name               = $name
        Provider           = $provider
        Model              = [string](Get-ConfigValue $Endpoint 'model')
        StatusCode         = $null
        TtfbMs             = $null
        TtftMs             = $null
        TotalMs            = $null
        InputTokens        = $null
        OutputTokens       = $null
        OutputTokensPerSec = $null
        StopReason         = ''
        ResponseChars      = $null
        ResponsePreview    = ''
        RequestId          = ''
        Success            = $false
        Error              = ''
    }

    if (-not $url)    { $result['Error'] = 'url が設定されていません'; return [pscustomobject]$result }
    if (-not $keyEnv) { $result['Error'] = 'apiKeyEnv が設定されていません'; return [pscustomobject]$result }

    $apiKey = [Environment]::GetEnvironmentVariable($keyEnv)
    if (-not $apiKey) {
        $result['Error'] = "環境変数 $keyEnv に API キーが設定されていません"
        return [pscustomobject]$result
    }

    $promptToSend = $Prompt
    if (-not $NoCacheBuster) {
        # 念のためのキャッシュ回避（Claude のプロンプトキャッシュは cache_control 明示時のみ有効）
        $promptToSend = "$Prompt`n(request-id: $([Guid]::NewGuid().ToString('N').Substring(0, 8)))"
    }

    $json = New-RequestBody -Endpoint $Endpoint -Prompt $promptToSend -MaxTokens $MaxTokens |
        ConvertTo-Json -Depth 10 -Compress

    $client   = $null
    $request  = $null
    $response = $null
    $reader   = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
        Set-RequestHeader -Request $request -Endpoint $Endpoint -ApiKey $apiKey
        $request.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')

        # ResponseHeadersRead にしないとボディ全体を受信し終わるまで戻らず、TTFB / TTFT が測れない
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $result['TtfbMs']     = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        $result['StatusCode'] = [int]$response.StatusCode

        try {
            $ids = $null
            if ($response.Headers.TryGetValues('request-id', [ref]$ids)) {
                $result['RequestId'] = ($ids | Select-Object -First 1)
            }
        } catch { }

        if (-not $response.IsSuccessStatusCode) {
            $errorBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $message = $errorBody
            try {
                $parsed = $errorBody | ConvertFrom-Json
                $err = Get-ConfigValue $parsed 'error'
                if ($err) { $message = "$(Get-ConfigValue $err 'type' '')/$(Get-ConfigValue $err 'message' '')" }
            } catch { }
            $sw.Stop()
            $result['TotalMs'] = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
            $result['Error']   = ($message -replace '\s+', ' ').Trim()
            return [pscustomobject]$result
        }

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)

        $text = New-Object System.Text.StringBuilder
        $firstDeltaMs = $null

        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.StartsWith('data:')) { continue }

            $payload = $line.Substring(5).Trim()
            if ($payload -eq '' -or $payload -eq '[DONE]') { continue }

            try { $evt = $payload | ConvertFrom-Json } catch { continue }

            if ($provider -eq 'anthropic') {
                switch ([string](Get-ConfigValue $evt 'type')) {
                    'message_start' {
                        $msg = Get-ConfigValue $evt 'message'
                        $usage = Get-ConfigValue $msg 'usage'
                        $result['InputTokens'] = Get-ConfigValue $usage 'input_tokens'
                        $m = Get-ConfigValue $msg 'model'
                        if ($m) { $result['Model'] = [string]$m }
                    }
                    'content_block_delta' {
                        if ($null -eq $firstDeltaMs) { $firstDeltaMs = $sw.Elapsed.TotalMilliseconds }
                        $delta = Get-ConfigValue $evt 'delta'
                        if ([string](Get-ConfigValue $delta 'type') -eq 'text_delta') {
                            [void]$text.Append([string](Get-ConfigValue $delta 'text' ''))
                        }
                    }
                    'message_delta' {
                        $result['StopReason'] = [string](Get-ConfigValue (Get-ConfigValue $evt 'delta') 'stop_reason' '')
                        $usage = Get-ConfigValue $evt 'usage'
                        if ($usage) { $result['OutputTokens'] = Get-ConfigValue $usage 'output_tokens' }
                    }
                    'error' {
                        $e = Get-ConfigValue $evt 'error'
                        $result['Error'] = "$(Get-ConfigValue $e 'type' '')/$(Get-ConfigValue $e 'message' '')"
                    }
                }
            } else {
                $choices = Get-ConfigValue $evt 'choices'
                if ($choices -and @($choices).Count -gt 0) {
                    $choice = @($choices)[0]
                    $content = Get-ConfigValue (Get-ConfigValue $choice 'delta') 'content'
                    if ($content) {
                        if ($null -eq $firstDeltaMs) { $firstDeltaMs = $sw.Elapsed.TotalMilliseconds }
                        [void]$text.Append([string]$content)
                    }
                    $finish = Get-ConfigValue $choice 'finish_reason'
                    if ($finish) { $result['StopReason'] = [string]$finish }
                }
                $usage = Get-ConfigValue $evt 'usage'
                if ($usage) {
                    $result['InputTokens']  = Get-ConfigValue $usage 'prompt_tokens'
                    $result['OutputTokens'] = Get-ConfigValue $usage 'completion_tokens'
                }
            }
        }

        $sw.Stop()
        $totalMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        $result['TotalMs'] = $totalMs
        if ($null -ne $firstDeltaMs) { $result['TtftMs'] = [math]::Round($firstDeltaMs, 1) }

        $body = $text.ToString()
        $result['ResponseChars'] = $body.Length
        $preview = ($body -replace '\s+', ' ').Trim()
        if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + '…' }
        $result['ResponsePreview'] = $preview

        # 生成速度は「最初のトークン以降」で算出する（待ち時間を含めると実態とずれるため）
        if ($result['OutputTokens'] -and $null -ne $firstDeltaMs) {
            $genSec = ($totalMs - $firstDeltaMs) / 1000
            if ($genSec -gt 0) {
                $result['OutputTokensPerSec'] = [math]::Round($result['OutputTokens'] / $genSec, 2)
            }
        }

        if (-not $result['Error']) { $result['Success'] = $true }
    } catch {
        $sw.Stop()
        $result['TotalMs'] = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        $result['Error'] = $ex.Message
    } finally {
        if ($reader)   { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request)  { $request.Dispose() }
        if ($client)   { $client.Dispose() }
    }

    return [pscustomobject]$result
}

# ---- 実行 ----------------------------------------------------------------

$config = Read-EndpointConfig -Path $ConfigFile
$endpoints = $config.Endpoints
if ($Only) {
    $endpoints = @($endpoints | Where-Object { $Only -contains [string](Get-ConfigValue $_ 'name') })
    if ($endpoints.Count -eq 0) { throw "-Only に一致するエンドポイントがありません: $($Only -join ', ')" }
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$detailCsv  = Join-Path $OutputDirectory "ai-api-$stamp.csv"
$summaryCsv = Join-Path $OutputDirectory "ai-api-$stamp-summary.csv"

$totalCycles = [math]::Max(1, [math]::Floor($DurationSeconds / $IntervalSeconds))

Write-Host "設定ファイル : $ConfigFile"
Write-Host "対象         : $($endpoints.Count) 件 ($((@($endpoints | ForEach-Object { Get-ConfigValue $_ 'name' })) -join ', '))"
Write-Host "プロンプト   : $($config.Prompt)"
Write-Host "測定条件     : $IntervalSeconds 秒間隔 x $totalCycles 回（約 $DurationSeconds 秒） / max_tokens=$($config.MaxTokens)"
Write-Host "出力先       : $detailCsv"
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]
$startTime = Get-Date

for ($cycle = 1; $cycle -le $totalCycles; $cycle++) {
    $scheduled = $startTime.AddSeconds($IntervalSeconds * ($cycle - 1))
    $wait = ($scheduled - (Get-Date)).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }

    foreach ($endpoint in $endpoints) {
        $result = Invoke-AiMeasurement -Cycle $cycle -Endpoint $endpoint -Prompt $config.Prompt -MaxTokens $config.MaxTokens
        $results.Add($result) | Out-Null
        $result | Export-Csv -LiteralPath $detailCsv -NoTypeInformation -Encoding $csvEncoding -Append

        $line = '[{0,3}/{1}] {2,-22} {3,4}  TTFT {4,7} ms  Total {5,8} ms  out {6,5} tok' -f `
            $cycle, $totalCycles, $result.Name,
            $(if ($null -ne $result.StatusCode) { $result.StatusCode } else { 'ERR' }),
            $(if ($null -ne $result.TtftMs) { $result.TtftMs } else { '-' }),
            $(if ($null -ne $result.TotalMs) { $result.TotalMs } else { '-' }),
            $(if ($null -ne $result.OutputTokens) { $result.OutputTokens } else { '-' })

        if ($result.Success) {
            Write-Host $line
        } else {
            Write-Host "$line  $($result.Error)" -ForegroundColor Yellow
        }
    }
}

# ---- 集計 ----------------------------------------------------------------

$summary = foreach ($group in ($results | Group-Object -Property Name)) {
    $ok      = @($group.Group | Where-Object { $_.Success })
    $totals  = @($ok | ForEach-Object { [double]$_.TotalMs })
    $ttfts   = @($ok | Where-Object { $null -ne $_.TtftMs } | ForEach-Object { [double]$_.TtftMs })
    $outToks = @($ok | Where-Object { $null -ne $_.OutputTokens } | ForEach-Object { [double]$_.OutputTokens })
    $tps     = @($ok | Where-Object { $null -ne $_.OutputTokensPerSec } | ForEach-Object { [double]$_.OutputTokensPerSec })

    [pscustomobject]@{
        Name            = $group.Name
        Model           = $group.Group[0].Model
        Requests        = $group.Count
        SuccessCount    = $ok.Count
        ErrorCount      = $group.Count - $ok.Count
        SuccessRate     = [math]::Round(100 * $ok.Count / $group.Count, 1)
        AvgTtftMs       = if ($ttfts.Count)   { [math]::Round(($ttfts   | Measure-Object -Average).Average, 1) } else { $null }
        MedianTtftMs    = Get-Percentile -Values $ttfts -Percentile 50
        AvgTotalMs      = if ($totals.Count)  { [math]::Round(($totals  | Measure-Object -Average).Average, 1) } else { $null }
        MedianTotalMs   = Get-Percentile -Values $totals -Percentile 50
        MinTotalMs      = if ($totals.Count)  { [math]::Round(($totals  | Measure-Object -Minimum).Minimum, 1) } else { $null }
        MaxTotalMs      = if ($totals.Count)  { [math]::Round(($totals  | Measure-Object -Maximum).Maximum, 1) } else { $null }
        P95TotalMs      = Get-Percentile -Values $totals -Percentile 95
        AvgOutputTokens = if ($outToks.Count) { [math]::Round(($outToks | Measure-Object -Average).Average, 1) } else { $null }
        AvgTokensPerSec = if ($tps.Count)     { [math]::Round(($tps     | Measure-Object -Average).Average, 2) } else { $null }
    }
}

$summary | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding $csvEncoding

Write-Host ''
Write-Host '===== 集計 ====='
$summary | Format-Table Name, Requests, SuccessCount, ErrorCount, AvgTtftMs, MedianTtftMs, AvgTotalMs, MedianTotalMs, P95TotalMs, AvgOutputTokens, AvgTokensPerSec -AutoSize
Write-Host "明細 CSV : $detailCsv"
Write-Host "集計 CSV : $summaryCsv"
