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

### 2. 解析する

```powershell
cd har-measure
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
| `-UrlFilter` | チャット系エンドポイントの正規表現 | 対象 URL の絞り込み |
| `-AllRequests` | オフ | 指定すると絞り込みなしで全リクエストを対象にする |
| `-Label` | — | 出力に付ける任意のラベル（条件の記録用） |
| `-OutputDirectory` | `results` | CSV の出力先 |

既定の `-UrlFilter` は `backend-api/...conversation` や `/v1/chat/completions` などのストリーミング系エンドポイントに当たるようにしてあります。何も引っかからない場合は `-AllRequests` で全件を見て、実際の URL を確認してから `-UrlFilter` を指定してください。

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

- **トークン数と生成速度は取れません。** HAR は SSE のチャンクごとの時刻を保存しないため、測れるのは `WaitMs` と `TotalMs` の2点です。
- **応答本文が残らないことがあります。** ストリーミングのレスポンスボディは HAR に記録されないか、途中までしか入らないのが普通です。所要時間の測定には影響しません。
- **毎回の手動操作が必要です。** 定期実行はできないので、時間帯比較などは自分で回数を稼ぐことになります。
- **HAR には Cookie や Authorization ヘッダが含まれます。** 中身は解析に使っていませんが、`captures/` は `.gitignore` 済みです。**HAR ファイルそのものを他人に渡さないでください**（セッションを乗っ取れてしまいます）。

正確な数字が要るなら、キーが取れるサービス（[ai-api-measure/](../ai-api-measure/) の `endpoints-free.json`）での測定と併用するのがおすすめです。

## 動作環境

Windows PowerShell 5.1 / PowerShell 7 以降。追加モジュールは不要です。
