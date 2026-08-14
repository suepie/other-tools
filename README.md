# other-tools

日々の作業で使う小さな便利ツールを、用途ごとにフォルダを分けて置いておくリポジトリです。

## ツール一覧

| フォルダ | 内容 | 環境 |
| --- | --- | --- |
| [network-measure/](network-measure/) | 複数サイトへ一定間隔で HTTP リクエストし、応答時間・ステータスコード・サイズを CSV に記録する | PowerShell 5.1 / 7+ |
| [ai-api-measure/](ai-api-measure/) | AI API へ短いプロンプトを一定間隔で投げ、TTFT・応答時間・トークン数・生成速度を CSV に記録する | PowerShell 5.1 / 7+ |
| [har-measure/](har-measure/) | ブラウザからエクスポートした HAR を解析し、リクエストごとの所要時間を CSV に集計する | PowerShell 5.1 / 7+ |
| [git-forge-aws/](git-forge-aws/) | プロジェクトごとに AWS アカウントを分けて、IP 制限付きの Forgejo（CI 込み）を ECS に立てる | Terraform 1.11+ / AWS |

## 追加するときの決まり

- ツールごとに 1 フォルダ。フォルダ名は英小文字のケバブケース。
- 各フォルダに `README.md` を置き、使い方・オプション・出力を書く。
- 実行結果などの成果物はコミットしない（各フォルダの `.gitignore` で除外する）。
- 上の一覧に 1 行追加する。
