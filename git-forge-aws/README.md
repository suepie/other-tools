# git-forge-aws

**プロジェクトごとに AWS アカウントを分けて、IP 制限付きの Forgejo（セルフホスト Git）を立てる Terraform** です。CI（Forgejo Actions）込みで、鍵をどこに置くかが分かるようにしてあります。

## 構成

```
                  固定IPからのみ
                       │
              [ALB + ACM]  ←── Route 53 (A レコード + DNS検証)
                       │ :3000
        ┌──────────────┴──────────────┐
        │   ECS Managed Instances     │  ← パッチはAWSが14日ごとに代行
        │  ┌──────────┐ ┌──────────┐  │
        │  │ Forgejo  │ │  Runner  │  │  ← runnerはlocalhost:3000でforgeへ
        │  └──────────┘ └──────────┘  │
        └──────┬────────┬────────┬────┘
               │        │        │
            [EFS]    [RDS]     [S3]
         ベアGitリポ  メタデータ  LFS/添付/Packages
                              /Actions成果物
```

`bootstrap/`（tfstate 置き場）と `ecs/`（本体）の 2 スタックです。**アカウントごとに 1 セット**作ります。

## データの置き場所

役割ごとに分けています。ここが設計の要点です。

| データ | 置き場所 | 理由 |
| --- | --- | --- |
| **ベア Git リポジトリ** | EFS | ファイルシステムが必須。Forgejo は共有 POSIX ストレージでの運用を公式にサポート |
| メタデータ全般 | RDS PostgreSQL | **SQLite は NFS 上でロックが壊れる**ため使えない |
| LFS / 添付 / アバター | S3 | Forgejo 公式が性能上の理由でオブジェクトストレージを推奨 |
| Packages | S3 | 同上 |
| Actions のログ / 成果物 | S3 | CI で書き込みが多い部分を EFS から外せる |

EFS が担うのは Git オブジェクトの読み書きだけになります。

## 秘密情報の置き場所

**これが「鍵をどこに入れるか」の答えです。**

| 何 | どこに置く | 置いてはいけない場所 |
| --- | --- | --- |
| Terraform 実行用の AWS 認証情報 | **AWS IAM Identity Center（`aws sso login`）**。CI からなら **OIDC + AssumeRole** | tfvars、リポジトリ、長期アクセスキーの環境変数 |
| tfstate | **S3（`bootstrap/` が作成）+ KMS 暗号化 + バージョニング** | ローカルのみ、Git |
| バックエンド設定（バケット名） | `ecs/backend.hcl`（`.gitignore` 済み） | Git |
| 環境固有の値（IP、FQDN） | `ecs/terraform.tfvars`（`.gitignore` 済み） | Git |
| DB パスワード | **Secrets Manager**（Terraform が生成 → ECS が IAM で注入） | tfvars、タスク定義に直書き |
| 管理者パスワード | **Secrets Manager** | 同上 |
| ランナー登録シークレット | **Secrets Manager** | 同上 |
| S3 アクセスキー | **Secrets Manager**（後述） | 同上 |
| **サーバへの SSH 鍵** | **作りません**（ECS Exec / SSM でアクセス） | — |
| TLS 証明書 | **ACM**（自動発行・自動更新） | インスタンス内 |
| 暗号化鍵 | **プロジェクト専用の KMS CMK** | — |
| Actions で使う秘密 | Forgejo の Secrets 機能 | ワークフローに直書き |

**タスク定義に平文の秘密は一切書きません。** Secrets Manager の ARN と JSON キー名だけを書き、ECS が起動時に注入します。

> ⚠️ **1 か所だけ長期クレデンシャルが必要です。**
> Forgejo（Gitea 系）の S3 クライアントは **IAM ロールの資格情報チェーンに未対応**で、アクセスキーとシークレットの指定が必須です（[go-gitea/gitea#32271](https://github.com/go-gitea/gitea/issues/32271)）。そのため専用の IAM ユーザーを作り、**このバケットとこの CMK にだけ**権限を絞っています。将来 Forgejo が IAM ロールに対応したら、この IAM ユーザーは削除できます。

> ⚠️ **生成した秘密は tfstate に入ります。** これは Terraform の仕様です。だから `bootstrap/` で tfstate を S3 + KMS + バージョニング + HTTPS 強制のバケットに置き、参照できる人を絞る前提になっています。

## 前提

- プロジェクト用の **AWS アカウント**（Organizations 配下を想定）
- そのアカウントの **Route 53 ホストゾーン**（ACM の DNS 検証に使用）
- **ECS Managed Instances が使えるリージョン**（東京は対応済み）
- Terraform **1.11 以降**、AWS provider **6.15 以降**（Managed Instances 対応版）
- AWS CLI

## 手順

### 1. 認証（アクセスキーは作らない）

```bash
aws sso login --profile project-a
export AWS_PROFILE=project-a
```

### 2. tfstate の置き場を作る（アカウントごとに1回）

```bash
cd bootstrap
terraform init
terraform apply -var project=project-a
terraform output -raw backend_config > ../ecs/backend.hcl
```

### 3. 変数を用意する

```bash
cd ../ecs
cp terraform.tfvars.example terraform.tfvars
# allowed_cidrs / domain_name / route53_zone_id / admin_email を埋める
```

### 4. 本体を作る

```bash
terraform init -backend-config=backend.hcl
terraform apply
```

ACM の DNS 検証と RDS の作成があるので、初回は 15〜20 分程度かかります。

### 5. 初期セットアップ（1回だけ）

forge サービスが安定したら、管理者作成とランナー登録を行う使い捨てタスクを実行します。

```bash
eval "$(terraform output -raw bootstrap_command)"
```

進捗は CloudWatch Logs（`terraform output log_group`）の `bootstrap` ストリームで確認できます。

### 6. ログインする

```bash
terraform output -raw admin_credentials_command | sh
```

URL・ユーザー名・パスワードが JSON で出ます。`allowed_cidrs` に入れた IP からアクセスしてください。

## アクセス方法

**Web / Git**: `https://<domain_name>/` — HTTPS のみです（SSH は無効化しています）。clone は Forgejo で発行したアクセストークンを使います。

```bash
git clone https://<user>:<token>@git-project-a.example.com/org/repo.git
```

**コンテナに入る**（SSH 鍵不要）:

```bash
eval "$(terraform output -raw exec_command)"
```

**ログ**: `aws logs tail /ecs/<project>/forge --follow`

## CI（Forgejo Actions）

ランナーは forge と同じインスタンスで動き、docker.sock 経由でジョブごとにコンテナを起動します。**この docker.sock が Fargate では使えないため、Managed Instances を選んでいます。**

`.forgejo/workflows/ci.yml`:

```yaml
on: [push]

jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: node --version
```

`runs-on` に書く値は `runner_labels` 変数のラベル名（既定 `docker`）です。

## 運用

| 項目 | どうなっているか |
| --- | --- |
| OS パッチ | **AWS が代行**（Managed Instances が 14 日ごとにインスタンスを入れ替え） |
| Forgejo の更新 | `forge_image` のタグを上げて `terraform apply` |
| Git リポジトリのバックアップ | EFS の自動バックアップ（AWS Backup の既定プラン）を有効化済み |
| DB のバックアップ | RDS 自動バックアップ 14 日（`db_backup_retention_days`） |
| S3 | バージョニング有効 |
| 誤削除対策 | S3 バケットと RDS に `prevent_destroy` / `deletion_protection` |

**インスタンスが 14 日ごとに入れ替わる前提の設計**なので、永続データは一切インスタンス上に置いていません。ランナーは共有シークレット方式で起動のたびに自動再登録されます。

## 分離の設計

| レイヤ | 分離手段 |
| --- | --- |
| アカウント | プロジェクトごとに AWS アカウント（課金・権限・監査が完全分離） |
| ネットワーク | プロジェクトごとに VPC。入口は ALB のみで固定 IP 制限 |
| 暗号化 | プロジェクト専用の KMS CMK（EFS / S3 / RDS / Secrets すべて） |
| 認証情報 | プロジェクトごとの Secrets Manager と IAM ユーザー |

## 検証状況と注意点

**`terraform validate` は通過していますが、実際の `apply` は未実施です。** 以下は最初の apply で確認が必要な箇所です。

| 箇所 | 内容 |
| --- | --- |
| `AmazonECSInfrastructureRolePolicyForManagedInstances` | Managed Instances 用のマネージドポリシー名。権限エラーが出たら AWS のドキュメントで現行名を確認してください（`ecs/iam.tf`） |
| イメージタグ | `forge_image` / `runner_image` は執筆時点のものです。公式で最新を確認して固定してください |
| ランナー登録 | `forgejo forgejo-cli actions register --secret` のサブコマンド名はバージョンで揺れます。bootstrap タスクが失敗したら、ECS Exec で forge コンテナに入って手動登録してください |
| docker.sock のマウント | Managed Instances でのホストボリュームマウントは、最初の apply で動作確認してください |
| EFS 上の Git 性能 | リポジトリが大きい場合は実測してください。厳しければ `../forge/`（EC2 + EBS 版）が代替になります |

**コストの主な要素**: ALB、Managed Instances（EC2 + 管理手数料）、RDS、EFS、S3、Route 53。プロジェクト数だけ掛かるので、構成を決めてから料金計算ツールで試算してください。

## `forge/` について

`forge/` は **EC2 + EBS 版**（SQLite、EFS/RDS なし）です。ECS 版に移行したため通常は使いませんが、次の場合の代替として残しています。

- EFS 上の Git 性能が要件を満たさなかった場合
- コストを最小にしたい場合（RDS と ALB 管理手数料が不要）

不要なら削除してかまいません。
