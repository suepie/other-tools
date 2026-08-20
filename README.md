# other-tools

日々の作業で使う小さな便利ツールを、用途ごとにフォルダを分けて置いておくリポジトリです。

## ツール一覧

| フォルダ | 内容 | 環境 |
| --- | --- | --- |
| [network-measure/](network-measure/) | 複数サイトへ一定間隔で HTTP リクエストし、応答時間・ステータスコード・サイズを CSV に記録する | PowerShell 5.1 / 7+ |
| [ai-api-measure/](ai-api-measure/) | AI API へ短いプロンプトを一定間隔で投げ、TTFT・応答時間・トークン数・生成速度を CSV に記録する | PowerShell 5.1 / 7+ |
| [har-measure/](har-measure/) | ブラウザからエクスポートした HAR を解析し、リクエストごとの所要時間を CSV に集計する | PowerShell 5.1 / 7+ |
| [git-forge-aws/](git-forge-aws/) | プロジェクトごとに AWS アカウントを分けて、IP 制限付きの Forgejo（CI 込み）を ECS に立てる | Terraform 1.11+ / AWS |

## 開発環境（devcontainer）

Windows での開発を想定して devcontainer を用意しています。Terraform・AWS CLI・Session Manager plugin・PowerShell が入った状態で立ち上がります。

### 事前に必要なもの

- Docker Desktop（**WSL2 バックエンド**）
- VS Code + Dev Containers 拡張

### 起動前に1回だけ

**ホスト側に `.aws` と `.claude` がないとコンテナ起動に失敗します**（バインドマウントの対象がないため）。

```cmd
mkdir %USERPROFILE%\.aws
mkdir %USERPROFILE%\.claude
```

社内ネットワークで TLS インスペクション（Netskope など）を通す場合は、ルート CA 証明書を `.devcontainer/certs/` に置いてください。詳細は [.devcontainer/certs/README.md](.devcontainer/certs/README.md)。**置かなくてもビルドは通ります。**

### 起動

VS Code でこのフォルダを開き、**「Reopen in Container」**を選ぶだけです。起動後に `post-create.sh` がツールのバージョンを表示するので、そこで揃っているか確認できます。

### 入っているもの

| ツール | 用途 |
| --- | --- |
| Terraform | `git-forge-aws/`（**1.11 以降が必要**。古いとポストクリエイトで警告が出ます） |
| AWS CLI v2 | 全般 |
| **Session Manager plugin** | `aws ecs execute-command` でコンテナに入る用。AWS CLI に同梱されていないため個別に入れています |
| **PowerShell 7** | `network-measure` / `ai-api-measure` / `har-measure` のスクリプト実行 |
| Docker CLI | ホストの Docker を利用（docker-outside-of-docker） |

`~/.aws` をマウントしているので、コンテナ内で `aws sso login` した認証情報はホストと共有されます。

### Windows で気をつける点

- **改行コード**は [.gitattributes](.gitattributes) で LF に正規化しています
- **`.ps1` は BOM 付き UTF-8 のまま**にしてください。Windows PowerShell 5.1 が日本語を ANSI と誤認するのを防ぐためで、VS Code 側にも `files.encoding: utf8bom` を設定済みです
- バインドマウントの I/O が遅いと感じる場合は、**WSL2 のファイルシステム側にクローン**すると改善します

## 追加するときの決まり

- ツールごとに 1 フォルダ。フォルダ名は英小文字のケバブケース。
- 各フォルダに `README.md` を置き、使い方・オプション・出力を書く。
- 実行結果などの成果物はコミットしない（各フォルダの `.gitignore` で除外する）。
- 上の一覧に 1 行追加する。
