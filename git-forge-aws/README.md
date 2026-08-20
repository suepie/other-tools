# git-forge-aws

**プロジェクトごとに AWS アカウントを分けて、IP 制限付きの Forgejo（セルフホスト Git）を立てる Terraform** です。CI（Forgejo Actions）込み、**独自ドメインも DNS 設定も不要**で、鍵をどこに置くかが分かるようにしてあります。

## 構成

```
                固定IPからのみ（WAF で制限）
                          │
                  [CloudFront]  ←── 既定ドメイン *.cloudfront.net
                          │            （正規のTLS証明書が最初から付く）
                    VPC オリジン
                          │ 私設経路・HTTP
                  [内部 ALB]  ←── プライベートサブネット。インターネットから到達不可
                          │ :3000
        ┌─────────────────┴─────────────────┐
        │      ECS Managed Instances        │  ← パッチはAWSが14日ごとに代行
        │   ┌──────────┐   ┌──────────┐     │
        │   │ Forgejo  │   │  Runner  │     │  ← runnerはlocalhost:3000でforgeへ
        │   └──────────┘   └──────────┘     │
        └──────┬────────────┬──────────┬────┘
               │            │          │
            [EFS]        [RDS]       [S3]
         ベアGitリポ    メタデータ   LFS/添付/Packages
                                    /Actions成果物
```

`bootstrap/`（tfstate 置き場）と `ecs/`（本体）の 2 スタックです。**アカウントごとに 1 セット**作ります。

### なぜ CloudFront を挟むのか

**ACM は `*.elb.amazonaws.com` の証明書を発行できません**（そのドメインを所有していないので DNS 検証が通らない）。ALB を直接公開する方式では、独自ドメインなしに HTTPS を張れません。

**CloudFront の既定ドメイン `*.cloudfront.net` には有効な証明書が最初から付いています。** これを使うことで、ドメインを1つも持たずに正規の HTTPS でアクセスできます。

さらに **VPC オリジン**により ALB を internal のままにできるので、**CloudFront が唯一の入口**であることが構成上保証されます。

## データの置き場所

| データ | 置き場所 | 理由 |
| --- | --- | --- |
| **ベア Git リポジトリ** | EFS | ファイルシステムが必須。Forgejo は共有 POSIX ストレージでの運用を公式にサポート |
| メタデータ全般 | RDS PostgreSQL | **SQLite は NFS 上でロックが壊れる**ため使えない |
| LFS / 添付 / アバター / Packages | S3 | Forgejo 公式が性能上の理由でオブジェクトストレージを推奨 |
| Actions のログ / 成果物 | S3 | CI で書き込みが多い部分を EFS から外せる |

## 秘密情報の置き場所

| 何 | どこに置く | 置いてはいけない場所 |
| --- | --- | --- |
| Terraform 実行用の AWS 認証情報 | **AWS IAM Identity Center（`aws sso login`）**。CI からなら **OIDC + AssumeRole** | tfvars、リポジトリ、長期アクセスキーの環境変数 |
| tfstate | **S3（`bootstrap/` が作成）+ KMS 暗号化 + バージョニング** | ローカルのみ、Git |
| バックエンド設定 | `ecs/backend.hcl`（`.gitignore` 済み） | Git |
| 環境固有の値（IP など） | `ecs/terraform.tfvars`（`.gitignore` 済み） | Git |
| DB / 管理者 / ランナー登録の各パスワード | **Secrets Manager**（Terraform が生成 → ECS が IAM で注入） | tfvars、タスク定義に直書き |
| S3 アクセスキー | **Secrets Manager**（後述） | 同上 |
| **サーバへの SSH 鍵** | **作りません**（ECS Exec / SSM でアクセス） | — |
| TLS 証明書 | **CloudFront 既定証明書**（管理不要） | — |
| 暗号化鍵 | **プロジェクト専用の KMS CMK** | — |
| Actions で使う秘密 | Forgejo の Secrets 機能 | ワークフローに直書き |

**タスク定義に平文の秘密は一切書きません。** Secrets Manager の ARN と JSON キー名だけを書き、ECS が起動時に注入します。

> ⚠️ **1 か所だけ長期クレデンシャルが必要です。**
> Forgejo（Gitea 系）の S3 クライアントは **IAM ロールの資格情報チェーンに未対応**で、アクセスキーとシークレットの指定が必須です（[go-gitea/gitea#32271](https://github.com/go-gitea/gitea/issues/32271)）。専用の IAM ユーザーを作り、**このバケットとこの CMK にだけ**権限を絞っています。

> ⚠️ **生成した秘密は tfstate に入ります。** これは Terraform の仕様です。だから `bootstrap/` で tfstate を S3 + KMS + バージョニングのバケットに置き、参照できる人を絞る前提になっています。

## 記入するファイルは 3 つだけ

| ファイル | 由来 | 中身 |
| --- | --- | --- |
| `bootstrap/terraform.tfvars` | `.example` をコピー | `project` と `region` の 2 つだけ |
| `ecs/backend.hcl` | **bootstrap の出力を流し込む**（手で書かない） | tfstate の置き場 |
| `ecs/terraform.tfvars` | `.example` をコピー | 下表の 3 項目 |

### `ecs/terraform.tfvars` に必須の 3 項目

| 変数 | 何を書くか | 例 |
| --- | --- | --- |
| `project` | プロジェクト識別子。全リソース名の接頭辞。英小文字・数字・ハイフンで 2〜31 文字 | `"project-a"` |
| `allowed_cidrs` | **接続を許可する固定 IP のリスト**。CloudFront 手前の WAF で制限します。`0.0.0.0/0` はバリデーションで弾かれます | `["203.0.113.10/32"]` |
| `admin_email` | 初期管理者のメールアドレス | `"admin@example.com"` |

### 複数アカウントを扱うなら `allowed_account_ids` も

必須ではありませんが、**強く推奨します**。

```hcl
allowed_account_ids = ["111111111111"]
```

ここに書いたアカウント以外の認証情報で実行すると、**Terraform がリソースを触る前にエラーで停止**します。プロジェクトごとにアカウントを分ける構成では、`AWS_PROFILE` の切り替え忘れによる誤適用が最大のリスクなので、これで潰しておくのが確実です。`bootstrap` 側にも同じ値を書いてください。

あわせて `direnv` で `.envrc` を置き、ディレクトリに入ったら自動で `AWS_PROFILE` が切り替わるようにしておくと事故が減ります。

```bash
# git-forge-aws/.envrc
export AWS_PROFILE=orga-project-a
```

**URL は CloudFront が払い出す `https://xxxxx.cloudfront.net/` になります。** ドメインの取得も DNS レコードの作成も不要です。

## 前提

`aws sso login` は**認証**を通すだけです。以下が別途必要です。

**1. SSO ロールの権限** — 実質的に管理者相当が要ります。

```
ec2(VPC/subnet/SG)  ecs  iam  kms  secretsmanager  rds  efs
elasticloadbalancing  cloudfront  wafv2  s3  logs
```

> ⚠️ **`iam:CreateUser` と `iam:CreateAccessKey` が要注意です。** S3 用の IAM ユーザー作成に必要ですが、SCP で禁止している組織が多くあります。禁止されている場合は、IAM ユーザーとアクセスキーを別途用意してもらい、`ecs/secrets.tf` の該当リソースを削除して Secrets Manager に手で登録する形に変えてください。

**2. リージョン** — **CloudFront VPC オリジンと ECS Managed Instances の両方に対応**している必要があります。東京（`ap-northeast-1`）は両方対応済みです。

> ℹ️ **東京では AZ `apne1-az3` が VPC オリジン非対応**です。この Terraform は `excluded_az_ids` 変数でその AZ を自動的に避けます。他リージョンを使う場合は対象外 AZ を確認して設定してください。

**3. ツール**

| ツール | 用途 |
| --- | --- |
| Terraform **1.11 以降** | S3 ネイティブロック（`use_lockfile`）に必要 |
| AWS provider **6.15 以降** | ECS Managed Instances 対応版。`terraform init` が自動取得 |
| AWS CLI v2 | bootstrap タスクの実行、Secrets の取り出し |
| **Session Manager plugin** | `aws ecs execute-command` でコンテナに入るために必要（別途インストール） |

**4. AWS プロファイル** — `aws sso login` の前に一度 `aws configure sso` が必要です。

**Route 53 のホストゾーンは不要です。**

## 手順

### 1. 認証

```bash
aws sso login --profile project-a
export AWS_PROFILE=project-a
```

### 2. tfstate の置き場を作る（アカウントごとに1回）

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # project と region を編集
terraform init
terraform apply
terraform output -raw backend_config > ../ecs/backend.hcl
```

> ℹ️ **bootstrap だけはローカル state です**（tfstate の置き場を作るスタック自身は、まだその置き場を使えないため）。失っても、バケットと KMS キーは残っているので `terraform import` で復旧できます。

### 3. 変数を用意する

```bash
cd ../ecs
cp terraform.tfvars.example terraform.tfvars
# project / allowed_cidrs / admin_email を埋める
```

### 4. 本体を作る

```bash
terraform init -backend-config=backend.hcl
terraform apply
```

**初回は 25〜35 分程度かかります。** VPC オリジンの作成に最大 15 分、CloudFront の配信開始と RDS の作成にそれぞれ数分〜十数分かかるためです。

### 5. 初期セットアップ（1回だけ）

forge サービスが安定したら、管理者作成とランナー登録を行う使い捨てタスクを実行します。

```bash
eval "$(terraform output -raw bootstrap_command)"
```

進捗は CloudWatch Logs（`terraform output log_group`）の `bootstrap` ストリームで確認できます。

### 6. ログインする

```bash
terraform output forge_url
terraform output -raw admin_credentials_command | sh
```

`allowed_cidrs` に入れた IP からアクセスしてください。それ以外からは WAF が 403 を返します。

## アクセス方法

**Web / Git**: `https://xxxxx.cloudfront.net/` — HTTPS のみです（SSH は無効化しています）。clone は Forgejo で発行したアクセストークンを使います。

```bash
git clone https://<user>:<token>@xxxxx.cloudfront.net/org/repo.git
```

**コンテナに入る**（SSH 鍵不要）:

```bash
eval "$(terraform output -raw exec_command)"
```

**ログ**: `aws logs tail /ecs/<project>/forge --follow`

**許可 IP を変える**: `terraform.tfvars` の `allowed_cidrs` を編集して `terraform apply`。WAF の IP セット更新は数分で反映されます。

## CloudFront と Git の相性について

事前に確認済みの実測値です。

| 項目 | 値 | 備考 |
| --- | --- | --- |
| **HTTP リクエストボディの最大サイズ** | **64 GB** | **push サイズは実質問題になりません** |
| **オリジン応答タイムアウト** | 1〜120 秒（本構成は **120 秒**） | クォータ申請でさらに引き上げ可 |
| オリジンのキープアライブ | 1〜300 秒（本構成は 60 秒） | |
| ヘッダ + クエリの長さ（ボディ除く） | 32,768 bytes | |
| URL 長 | 8,192 bytes | |

**オリジン応答タイムアウトは「合計時間」ではなく「無通信が続いた時間」です。** データが流れ続けている限りタイムアウトしないので、10 分かかる clone でも問題ありません。

効いてくるのは**無通信区間**です。典型的なのは **push 後にサーバが pack を展開・フック実行・ref 更新している間**で、大きな push だと既定の 30 秒を超えます。本構成では最初から 120 秒にしてあります。足りなければ `origin_read_timeout` を上げ、120 秒を超える必要があればクォータ引き上げを申請してください。

Git 側でも調整できます。

```bash
git config --global http.postBuffer 157286400
git config --global http.lowSpeedLimit 1000
git config --global http.lowSpeedTime 60
```

**キャッシュは完全に無効化しています**（`Managed-CachingDisabled` + `Managed-AllViewer`）。有効だと Git の応答が壊れます。

## 運用

| 項目 | どうなっているか |
| --- | --- |
| OS パッチ | **AWS が代行**（Managed Instances が 14 日ごとにインスタンスを入れ替え） |
| Forgejo の更新 | `forge_image` のタグを上げて `terraform apply` |
| Git リポジトリのバックアップ | EFS の自動バックアップを有効化済み |
| DB のバックアップ | RDS 自動バックアップ 14 日 |
| S3 | バージョニング有効 |
| 誤削除対策 | S3 バケットに `prevent_destroy`、RDS に `deletion_protection` |

**インスタンスが 14 日ごとに入れ替わる前提の設計**なので、永続データは一切インスタンス上に置いていません。ランナーは共有シークレット方式で起動のたびに自動再登録されます。

## 分離の設計

| レイヤ | 分離手段 |
| --- | --- |
| アカウント | プロジェクトごとに AWS アカウント（課金・権限・監査が完全分離） |
| ネットワーク | プロジェクトごとに VPC。ALB は internal で、入口は CloudFront のみ |
| アクセス制御 | WAF による固定 IP 許可リスト（既定は拒否） |
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

**コストの主な要素**: CloudFront、**WAF（Web ACL の基本料金 + ルール + リクエスト課金）**、ALB、Managed Instances（EC2 + 管理手数料）、RDS、EFS、S3。プロジェクト数だけ掛かるので、構成を決めてから料金計算ツールで試算してください。

## `forge/` について

`forge/` は **EC2 + EBS 版**（SQLite、EFS/RDS/CloudFront なし）です。ECS 版に移行したため通常は使いませんが、EFS 上の Git 性能が要件を満たさなかった場合や、コストを最小にしたい場合の代替として残しています。不要なら削除してかまいません。

**※ こちらは独自ドメイン + Route 53 が必要な構成のままです。**
