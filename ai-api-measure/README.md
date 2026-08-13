# ai-api-measure

AI API へ**決まった短いプロンプト**を一定間隔で投げ、応答時間・トークン数・生成速度を CSV に記録する PowerShell スクリプトです。ストリーミング（SSE）で受信するため、「最初の一文字が返るまで」と「生成が終わるまで」を分けて測れます。

単純な GET を測る [network-measure/](../network-measure/) と違い、AI API はリクエストごとに推論時間が乗ります。ネットワークの速さではなく **API の応答性能**を見るためのツールです。

## 構成

| ファイル | 内容 |
| --- | --- |
| `Measure-AiApi.ps1` | 測定スクリプト本体 |
| `endpoints.json` | 測定対象のエンドポイント定義とプロンプト |
| `results/` | CSV の出力先（自動作成、Git 管理外） |

## 使い方

API キーは環境変数から読みます。設定ファイルに直接書く必要はありません。

```powershell
cd ai-api-measure
$env:ANTHROPIC_API_KEY = 'sk-ant-...'
.\Measure-AiApi.ps1
```

実行ポリシーで止められる場合：

```powershell
powershell -ExecutionPolicy Bypass -File .\Measure-AiApi.ps1
```

### 主なオプション

```powershell
# 30 秒間隔で 10 分間測る
.\Measure-AiApi.ps1 -IntervalSeconds 30 -DurationSeconds 600

# 特定のエンドポイントだけ測る
.\Measure-AiApi.ps1 -Only 'Claude Opus 5','Claude Haiku 4.5'
```

| パラメータ | 既定値 | 説明 |
| --- | --- | --- |
| `-ConfigFile` | `endpoints.json` | エンドポイント定義ファイル |
| `-IntervalSeconds` | `10` | リクエスト間隔（秒） |
| `-DurationSeconds` | `60` | 測定の総時間（秒） |
| `-OutputDirectory` | `results` | CSV の出力先 |
| `-TimeoutSeconds` | `120` | 1 リクエストのタイムアウト |
| `-Only` | — | 指定した名前のエンドポイントだけ測る（複数可） |
| `-NoCacheBuster` | オフ | プロンプト末尾のランダム識別子を付けない |

> AI API は 1 リクエストに数秒かかります。`-IntervalSeconds` を短くしすぎると次のサイクルに食い込んで測定周期が乱れるため、既定を 10 秒にしています。

## エンドポイント定義

`endpoints.json` にプロンプトと対象を書きます。

```json
{
  "prompt": "「OK」とだけ返答してください。",
  "maxTokens": 64,
  "endpoints": [
    {
      "name": "Claude Opus 5",
      "provider": "anthropic",
      "url": "https://api.anthropic.com/v1/messages",
      "model": "claude-opus-5",
      "apiKeyEnv": "ANTHROPIC_API_KEY",
      "thinking": "disabled",
      "effort": "low"
    }
  ]
}
```

| フィールド | 必須 | 説明 |
| --- | --- | --- |
| `name` | — | 表示名・集計キー（省略時はモデル名） |
| `provider` | — | `anthropic`（既定）または `openai-compatible` |
| `url` | ✅ | エンドポイント URL |
| `model` | ✅ | モデル ID |
| `apiKeyEnv` | ✅ | API キーが入っている**環境変数名** |
| `thinking` | — | `disabled` / `adaptive` / `none`（既定 `none` = パラメータを送らない） |
| `effort` | — | `low` / `medium` / `high` / `xhigh` / `max`。指定時のみ送信 |
| `betas` | — | `anthropic-beta` ヘッダに入れる値の配列 |
| `headers` | — | 追加ヘッダ（オブジェクト） |
| `authHeader` | — | `openai-compatible` 用。`bearer`（既定）/ `api-key`（Azure OpenAI） |
| `maxTokensField` | — | `openai-compatible` 用。既定 `max_tokens` |

### 測定値を安定させるための既定

`thinking: "disabled"` + `effort: "low"` + 小さめの `maxTokens` を推奨しています。思考（extended thinking）が有効だと出力量がリクエストごとに大きくブレて、応答時間の比較になりません。

- **Claude Opus 5 は思考が既定でオン**です。オフにするには `thinking: "disabled"` を明示してください。なお Opus 5 で思考オフにできるのは `effort` が `high` 以下のときだけで、`xhigh` / `max` と組み合わせると 400 になります。
- `effort` に対応していないモデル（Haiku 4.5 など）に `effort` を送るとエラーになります。サンプルでも Haiku 4.5 には付けていません。

### OpenAI 互換エンドポイント

Azure OpenAI やローカル LLM（Ollama、LM Studio など）も同じ CSV で比較できます。

```json
{
  "name": "Local LLM",
  "provider": "openai-compatible",
  "url": "http://localhost:11434/v1/chat/completions",
  "model": "llama3",
  "apiKeyEnv": "LOCAL_LLM_API_KEY"
}
```

## 出力

実行のたびにタイムスタンプ付きで 2 つの CSV を出力します（BOM 付き UTF-8 なので Excel でそのまま開けます）。中断しても残るよう 1 行ずつ追記しています。

### 明細 `results/ai-api-YYYYMMDD-HHmmss.csv`

| 列 | 内容 |
| --- | --- |
| `Timestamp` / `Cycle` | リクエスト開始時刻と何サイクル目か |
| `Name` / `Provider` / `Model` | 対象の表示名・プロバイダ・実際に応答したモデル |
| `StatusCode` | HTTP ステータス |
| `TtfbMs` | レスポンスヘッダが返るまで（ミリ秒） |
| `TtftMs` | **最初のトークンが届くまで**（ミリ秒）。体感の待ち時間 |
| `TotalMs` | ストリーム完了まで（ミリ秒） |
| `InputTokens` / `OutputTokens` | 入出力トークン数 |
| `OutputTokensPerSec` | 生成速度。`OutputTokens ÷ (TotalMs − TtftMs)` で算出 |
| `StopReason` | 停止理由（`end_turn` / `max_tokens` / `refusal` など） |
| `ResponseChars` / `ResponsePreview` | 応答の文字数と先頭 60 文字 |
| `RequestId` | `request-id` ヘッダ（問い合わせ時に使えます） |
| `Success` / `Error` | 成否とエラー内容 |

### 集計 `results/ai-api-YYYYMMDD-HHmmss-summary.csv`

対象ごとの `Requests` / `SuccessCount` / `ErrorCount` / `SuccessRate` と、`TtftMs` と `TotalMs` の平均・中央値・最小・最大・P95、平均出力トークン数、平均生成速度。同じ内容が終了時にコンソールにも表示されます。

## キャッシュについて

既定でプロンプト末尾に `(request-id: xxxxxxxx)` を付けています（`-NoCacheBuster` で無効化）。ただし **Claude のプロンプトキャッシュは `cache_control` を明示したときだけ有効**で、このスクリプトは指定していません。加えてキャッシュ対象になる最小プレフィックスはモデルにより 512〜4096 トークンで、この短いプロンプトはそもそも届きません。つまりキャッシュバスターは念のための保険です。

## 注意

- **課金されます。** 実行するたびに実際の API リクエストが飛びます。既定（10 秒間隔 × 6 サイクル × エンドポイント数）でも、長時間回すときはトークン数と回数を意識してください。
- API キーは環境変数からのみ読み、CSV にもコンソールにも出力しません。
- レート制限に当たった場合は `429` としてエラー行に残り、リトライはしません（リトライすると測定値が歪むため）。

## 動作環境

Windows PowerShell 5.1 / PowerShell 7 以降。追加モジュールは不要です。
