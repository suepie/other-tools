# network-measure

複数サイトへ一定間隔で HTTP リクエストを行い、**応答時間・ステータスコード・レスポンスサイズ**を CSV に記録する PowerShell スクリプトです。既定では **3 秒間隔で 60 秒間（20 サイクル）** 測定します。

## 構成

| ファイル | 内容 |
| --- | --- |
| `Measure-Network.ps1` | 測定スクリプト本体 |
| `targets.txt` | 測定対象の一覧（1 行 1 対象） |
| `results/` | CSV の出力先（自動作成、Git 管理外） |

## 使い方

```powershell
cd network-measure
.\Measure-Network.ps1
```

実行ポリシーで止められる場合は、そのセッションだけ緩和して実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\Measure-Network.ps1
```

### 主なオプション

```powershell
# 5 秒間隔で 5 分間測定する
.\Measure-Network.ps1 -IntervalSeconds 5 -DurationSeconds 300

# 別の対象リスト・別の出力先を使う
.\Measure-Network.ps1 -TargetFile .\targets-prod.txt -OutputDirectory D:\logs
```

| パラメータ | 既定値 | 説明 |
| --- | --- | --- |
| `-TargetFile` | `targets.txt` | 測定対象の一覧ファイル |
| `-IntervalSeconds` | `3` | リクエスト間隔（秒） |
| `-DurationSeconds` | `60` | 測定の総時間（秒） |
| `-OutputDirectory` | `results` | CSV の出力先 |
| `-TimeoutSeconds` | `10` | 1 リクエストのタイムアウト（間隔より長くすると測定周期が乱れます） |
| `-KeepAlive` | オフ | 指定すると TCP 接続を再利用する |
| `-NoCacheBuster` | オフ | 指定するとキャッシュバスターを付けない |
| `-UserAgent` | `NetworkMeasure/1.0` | 送信する User-Agent |

## 対象ファイルの書き方

`targets.txt` は 1 行 1 対象です。`#` で始まる行と空行は無視されます。

```text
# URL だけ書く（表示名はホスト名になる）
https://www.google.com/

# 「表示名,URL」で書く
Yahoo! JAPAN,https://www.yahoo.co.jp/

# スキームを省略すると https:// を補う
www.microsoft.com
```

同梱の `targets.txt` には、一般サイトに加えて AI サービス（`api.openai.com` / `api.anthropic.com` / `chatgpt.com`）への到達性チェックも入れてあります。認証なしなので `401`（`chatgpt.com` はボット判定で `403` のことも）が返りますが、それで正常です。**推論そのものの速さは測れません** — それは [ai-api-measure/](../ai-api-measure/) と [har-measure/](../har-measure/) の担当です。

## キャッシュ対策

「キャッシュが効いて速く見えてしまう」のを避けるため、既定で次の 3 つを行っています。

1. **`Cache-Control: no-cache, no-store, max-age=0` と `Pragma: no-cache` ヘッダを付与** — 途中の CDN やプロキシに再検証を要求します。
2. **キャッシュバスター** — URL に毎回異なる `_nc=<GUID>` を付けるので、キャッシュのキーが毎回変わり必ずオリジンまで到達します。`-NoCacheBuster` で無効化できます。
3. **Keep-Alive 無効化** — 毎回 TCP／TLS ハンドシェイクからやり直すため、接続再利用による見かけ上の高速化が起きません。`-KeepAlive` で再利用させることもできます。

補足として、DNS の解決結果は .NET 側でキャッシュされるため、2 回目以降の DNS 解決時間は測定値に含まれにくくなります。純粋な接続確立コストまで見たい場合は、この点を踏まえて解釈してください。

## 出力

実行するたびにタイムスタンプ付きで 2 つの CSV を出力します（BOM 付き UTF-8 なので Excel でそのまま開けます）。

### 明細 `results/network-YYYYMMDD-HHmmss.csv`

1 リクエスト 1 行。中断しても途中までの結果が残るよう、1 行ずつ追記しています。

| 列 | 内容 |
| --- | --- |
| `Timestamp` | リクエスト開始時刻（ミリ秒まで）。時系列グラフにしたときサンプル点が測定周期と揃います |
| `Cycle` | 何サイクル目か |
| `Name` / `Url` | 対象の表示名と URL |
| `StatusCode` / `StatusText` | HTTP ステータス（接続自体に失敗した場合は空） |
| `ElapsedMs` | リクエスト開始から応答受信完了までの時間（ミリ秒） |
| `SizeBytes` | レスポンスサイズ（不明な場合は `-1`） |
| `ThroughputKBps` | `SizeBytes` / `ElapsedMs` から算出したスループット |
| `ContentType` | レスポンスの Content-Type |
| `Responded` | サーバから HTTP 応答が返ったか。`401`/`403` でも `True`（到達性の測定値としては有効なため） |
| `Success` / `Error` | 2xx/3xx だったかと、エラーメッセージ |

### 集計 `results/network-YYYYMMDD-HHmmss-summary.csv`

対象ごとに次を出力します。同じ内容が実行終了時にコンソールにも表示されます。

| 列 | 内容 |
| --- | --- |
| `Requests` | リクエスト数 |
| `OkCount` | 2xx/3xx が返った回数 |
| `HttpErrorCount` | 応答は返ったが 4xx/5xx だった回数 |
| `NoResponseCount` | 接続できなかった（タイムアウト・DNS 失敗など）回数 |
| `OkRate` | `OkCount` の割合（%） |
| `AvgMs` `MedianMs` `MinMs` `MaxMs` `P95Ms` | 応答時間。**`OkCount` と `HttpErrorCount` の両方**を対象に集計します |
| `AvgSizeBytes` | 2xx/3xx だったリクエストの平均サイズ |

応答時間を 4xx/5xx も含めて集計しているのは、認証なしで叩く API のように「`401` が返ってくること自体が正常」な対象を測れるようにするためです。接続できなかった行（`NoResponseCount`）は所要時間が意味を持たないので除外しています。

## 動作環境

Windows PowerShell 5.1 / PowerShell 7 以降。追加モジュールは不要です。
