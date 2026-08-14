# har-measure

ブラウザからエクスポートした **HAR ファイル**を解析し、リクエストごとの所要時間を CSV に集計する PowerShell スクリプトです。

API キーを払い出せない環境で、ChatGPT のような Web UI の応答時間を実測したいときに使います。**自動操作は一切しません** — 人がブラウザで普通に使い、DevTools が記録した結果を後から読むだけなので、対象サービスの利用規約に触れません。

## 構成

| ファイル | 内容 |
| --- | --- |
| `Measure-FromHar.ps1` | 解析スクリプト本体 |
| `results/` | CSV の出力先（自動作成、Git 管理外） |
| `captures/` | HAR の置き場（任意、Git 管理外） |

## 使い方

### 1. HAR を取る

1. ブラウザ（Chrome / Edge）で対象サイトを開く
2. `F12` で DevTools →「ネットワーク」タブ
3. **「ログを保存」（Preserve log）にチェック**を入れる
4. 普通に質問を投げて、応答が終わるまで待つ
5. ネットワークタブの**ダウンロードアイコン →「HAR をエクスポート」**でファイル保存

比較したいなら、同じ質問文を時間帯や回線を変えて数回投げてから 1 つの HAR にまとめてエクスポートすると楽です。

### 2. どの URL を測るか特定する（初回は必ずこれ）

**測定対象のサービスが初めてなら、まず `-Discover` を実行してください。**

```powershell
cd har-measure
.\Measure-FromHar.ps1 .\captures\m365.har -Discover
```

絞り込みをせずに全リクエストを読み、次を表示します。

- **ホスト別**のリクエスト数と最長時間
- **ストリーミング応答**（`text/event-stream`）の一覧
- **時間のかかった POST 上位20** ← チャット本体の最有力候補

チャットの応答は「POST」「時間がかかる」「event-stream か JSON」という特徴が出るので、ここから対象 URL を見つけられます。

### 3. 解析する

見つけた URL に当たる正規表現を渡します。

```powershell
.\Measure-FromHar.ps1 .\captures\ -UrlFilter 'substrate\.office\.com.*chat'
```

既定の `-UrlFilter` を使う場合:

```powershell
.\Measure-FromHar.ps1 .\captures\chatgpt.har
```

```powershell
# ディレクトリ内の *.har をまとめて処理し、条件をラベルで残す
.\Measure-FromHar.ps1 .\captures\ -Label '社内LAN 昼'

# 絞り込みをやめてページ読み込み全体を見る
.\Measure-FromHar.ps1 .\captures\chatgpt.har -AllRequests
```

| パラメータ | 既定値 | 説明 |
| --- | --- | --- |
| `-Path` | カレントディレクトリ | HAR ファイルまたはディレクトリ（複数可） |
| `-UrlFilter` | ChatGPT 系エンドポイントの正規表現 | 対象 URL の絞り込み |
| `-Discover` | オフ | 探索モード。候補を表示して終了する |
| `-AllRequests` | オフ | 絞り込みなしで全リクエストを集計対象にする |
| `-Label` | — | 出力に付ける任意のラベル（条件の記録用） |
| `-OutputDirectory` | `results` | CSV の出力先 |

## 絞り込みのロジック

HAR 内の各エントリの **URL 全体**に対して `-UrlFilter` の正規表現を `-match` し、**マッチしないものを捨てて**います（大文字小文字は区別しません）。

既定値は次のとおりです。

```
(backend-api/.*conversation|/api/(chat|conversation)|/v1/(chat/)?completions|/v1/messages|/conversation\b)
```

> ⚠️ **これは ChatGPT / OpenAI / Anthropic 系のエンドポイント向けです。**
> Microsoft 365 や Google など別サービスのチャットは URL 体系がまったく違うため、既定値では当たりません。**別サービスを測るときは必ず `-Discover` で実際の URL を確認してから `-UrlFilter` を指定してください。**
> 既定値のまま実行して数件だけ引っかかった場合、それはチャット本体ではなく、たまたま `/conversation` などを含む無関係な通信である可能性があります。

## 読み方

HAR の `timings` をそのまま列にしています。ストリーミング応答（SSE）では次のように対応します。

| 列 | 意味 | ストリーミング応答での解釈 |
| --- | --- | --- |
| `WaitMs` | リクエスト送信〜レスポンス先頭が返るまで | **実質 TTFT**（最初の一文字までの待ち時間） |
| `ReceiveMs` | レスポンス本体の受信時間 | **実質「生成にかかった時間」** |
| `TotalMs` | リクエスト全体（HAR の `time`） | 質問してから生成完了までの合計 |

そのほか `BlockedMs` / `DnsMs` / `ConnectMs` / `SslMs` / `SendMs` で接続確立の内訳が、`ContentBytes` / `TransferBytes` でサイズが分かります。HAR で計測不能を示す `-1` は空欄にしています。

### 出力

実行のたびに 2 つの CSV を出力します（BOM 付き UTF-8）。

- **明細** `results/har-YYYYMMDD-HHmmss.csv` — 1 リクエスト 1 行。`SourceFile` / `Label` / `StartedAt` / `Method` / `Host` / `UrlPath` / `StatusCode` / `MimeType` / 各 timings / サイズ / `Url`
- **集計** `results/har-YYYYMMDD-HHmmss-summary.csv` — ホスト＋パスごとの件数と、`WaitMs` / `ReceiveMs` / `TotalMs` の平均・中央値・最小・最大・P95

## 限界

正直なところ、[ai-api-measure/](../ai-api-measure/) の API 直叩きより取れる情報は少ないです。

- **WebSocket で通信するサービスは測れません。** HAR は WebSocket を「1本の長時間接続」として記録するため、メッセージ単位の応答時間が取れません。`-Discover` を実行してチャット送信に対応する POST が見つからない場合、そのサービスは WebSocket を使っている可能性が高く、このツールでは測定できません。
- **トークン数と生成速度は取れません。** HAR は SSE のチャンクごとの時刻を保存しないため、測れるのは `WaitMs` と `TotalMs` の2点です。
- **応答本文が残らないことがあります。** ストリーミングのレスポンスボディは HAR に記録されないか、途中までしか入らないのが普通です。所要時間の測定には影響しません。
- **毎回の手動操作が必要です。** 定期実行はできないので、時間帯比較などは自分で回数を稼ぐことになります。
- **HAR には Cookie や Authorization ヘッダが含まれます。** 中身は解析に使っていませんが、`captures/` は `.gitignore` 済みです。**HAR ファイルそのものを他人に渡さないでください**（セッションを乗っ取れてしまいます）。

正確な数字が要るなら、キーが取れるサービス（[ai-api-measure/](../ai-api-measure/) の `endpoints-free.json`）での測定と併用するのがおすすめです。

## 動作環境

Windows PowerShell 5.1 / PowerShell 7 以降。追加モジュールは不要です。
