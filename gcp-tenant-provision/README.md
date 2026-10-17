# gcp-tenant-provision

**CSV を入力に、テナント用の Google Cloud プロジェクトを一括で払い出す bash スクリプト**です。プロジェクト作成に加えて、サービスアカウント（SA）の作成、Shared VPC ホスト側への EGRESS ファイアウォールルール作成、サービスプロジェクト側 GCE への SA 紐づけまでを一度に行います。gcloud CLI だけで動くので Cloud Shell でそのまま実行できます。

## 何をするか

```
input.csv（Excel から保存）
    │
    ▼
[1] project   新プロジェクト作成 → 課金アカウント紐づけ → API 有効化
[2] sa        新プロジェクト内に SA を作成
[3] firewall  FW プロジェクト（Shared VPC ホスト）に EGRESS ルールを作成
              target-service-accounts = [2] で作った SA
[4] gce       GCE プロジェクト（サービスプロジェクト）のインスタンスに [2] の SA を紐づけ
    │
    ▼
out/result_<コマンド>_<日時>.csv（行ごと・フェーズごとの成否）
```

```
                 親フォルダ
                    │
     ┌──────────────┼──────────────┐
  tenant-0001   tenant-0002   ...      ← CSV の行ごとに作成
   └ SA          └ SA
      │             │  target-service-accounts
      ▼             ▼
  ┌──────────────────────────────┐
  │ FW プロジェクト (Shared VPC ホスト) │  ← EGRESS ルール "egress-<project_id>"
  │   VPC: shared-vpc            │
  └──────────────┬───────────────┘
                 │ Shared VPC
  ┌──────────────┴───────────────┐
  │ GCE プロジェクト (サービス)   │  ← vm-tenant-0001 を tenant-0001 の SA で動かす
  └──────────────────────────────┘
```

## 前提条件

スクリプトは以下を**やりません**。事前に整えておいてください。`validate` で確認できるものは確認します。

| 項目 | 内容 | validate で確認 |
| --- | --- | --- |
| 実行者の権限 | 親フォルダに `roles/resourcemanager.projectCreator`、課金アカウントに `roles/billing.user`、FW プロジェクトに `roles/compute.securityAdmin`、GCE プロジェクトに `roles/compute.instanceAdmin.v1`、作成した SA への `roles/iam.serviceAccountUser`（新プロジェクトのオーナーなら自動で満たす） | 一部 |
| 組織ポリシー | 親フォルダで `iam.disableCrossProjectServiceAccountUsage` を**解除済み**であること。有効だと GCE に他プロジェクトの SA を付けられない | 警告のみ |
| Compute サービスエージェントの権限 | GCE プロジェクトの `service-<GCE_PROJECT_NUMBER>@compute-system.iam.gserviceaccount.com` に、各 SA への `roles/iam.serviceAccountTokenCreator` を付与する。**SA 作成後に手動で行う**（gce フェーズが未付与を検出すると、実行すべきコマンドをそのまま出力する） | gce フェーズで確認 |
| Shared VPC | FW プロジェクトがホスト、GCE プロジェクトがサービスプロジェクトであること | しない |
| GCE の停止 | SA の付け替えはインスタンスが **TERMINATED** でないとできない。起動中ならエラーにして報告だけする（自動停止はしない） | plan で分かる |
| プロジェクト作成クォータ | 組織の既定は少なめ。大量に作る前に割り当てを確認する | しない |

## セットアップ

```bash
cd gcp-tenant-provision
cp config.env.example config.env   # 環境固有の値を入れる（コミット対象外）
gcloud auth login
```

必要なもの: bash 4 以降、gcloud CLI、awk、iconv。Cloud Shell と devcontainer は揃っています。macOS 標準の bash は 3.2 なので動きません。

## CSV の作り方

Excel で下の列を作り、**「CSV UTF-8 (コンマ区切り)」**で保存してください。列の並び順は問いません。雛形は [input.csv.example](input.csv.example) にあります。

| 列 | 例 | 説明 |
| --- | --- | --- |
| project_id | tenant-0001 | 全世界で一意。6〜30 文字、英小文字始まり、英小文字/数字/ハイフン |
| display_name | テナント0001 | プロジェクト表示名 |
| sa_name | app-runner | SA 名。メールは `app-runner@tenant-0001.iam.gserviceaccount.com` になる |
| fw_dest_ranges | 10.0.1.0/24;10.0.2.0/24 | 出ていける宛先 CIDR。複数は `;` 区切り |
| fw_allow | tcp:443;tcp:8443 | 許可プロトコル/ポート。複数は `;` 区切り。`icmp` `all` も可 |
| gce_instance | vm-tenant-0001 | SA を付ける GCE。**空ならこの行の gce フェーズをスキップ** |
| gce_zone | asia-northeast1-a | gce_instance を書いたら必須 |

環境で共通の値（親フォルダ、課金アカウント、FW プロジェクト、VPC 名、GCE プロジェクト）は CSV ではなく `config.env` に置きます。Excel でのコピペ事故を減らすためです。

Excel 由来の以下はスクリプト側で吸収します。

- 先頭の BOM、CRLF
- カンマを含む値のダブルクォート囲み
- 各セル前後の半角/全角スペース
- 末尾に残る空行（`,,,,,,`）
- Shift-JIS で保存された場合は**エラーにして止めます**（文字化けしたまま gcloud に渡さない）

**1 プロジェクトに複数の GCE** を付けたいときは、同じ project_id の行を複数書きます。project/sa/firewall の値は全行で同じにしてください（違うと validate で止まります）。

## 使い方

```bash
./provision.sh validate input.csv     # CSV と設定・権限の事前チェックのみ
./provision.sh plan     input.csv     # 実行予定の gcloud コマンドを表示（何も変更しない）
./provision.sh apply    input.csv     # 作成
./provision.sh export   input.csv     # 実行スクリプトを生成（レビューして手動実行する運用向け）
./provision.sh evidence input.csv     # 実状態を取得し、CSV の期待値と突き合わせて証跡を保存
./provision.sh destroy  input.csv     # 削除（確認プロンプトあり）
```

apply で一気に流す運用と、export でスクリプトを出してレビューしてから手動で流す運用のどちらでも使えます。どちらの場合も最後に evidence で証跡を取ります。

| オプション | 説明 |
| --- | --- |
| `--phase project\|sa\|firewall\|gce` | そのフェーズだけ対象にする。例: 停止し忘れた GCE を止めたあと `apply --phase gce`。export / evidence にも効く |
| `--config FILE` | 設定ファイルの場所（既定: `./config.env`） |
| `--out-dir DIR` | 結果 CSV とログの出力先（既定: `./out`） |
| `--yes` | destroy の確認を省略する |

推奨の流れは **validate → plan → apply** です。plan は既存リソースの有無や GCE の起動状態を実際に見にいくので、「このインスタンスは起動中なので失敗する」といったことが apply 前に分かります。

### 冪等性と再実行

- 既にあるものは作らず `EXISTS` と記録します。途中で落ちても、そのまま同じ CSV で再実行すれば続きから進みます。
- 1 行の失敗は他の行に影響しません。失敗した project_id は後続フェーズで `SKIPPED` になります。
- **FW ルールだけは既存でも更新します**（`UPDATED`）。CSV の宛先やポートを変えて再実行すれば反映される、という意味です。
- 終了コードは 1 件でも `FAILED` があれば 1 です。

### destroy

`gce`（SA を既定の Compute SA に戻す）→ `firewall`（ルール削除）→ `project`（プロジェクト削除。SA も一緒に消える）の順に消します。プロジェクト削除は 30 日間の保留状態になり、その間は同じ project_id で作り直せません。

### export（スクリプト生成 → レビュー → 手動実行）

`out/export_<日時>/` にフェーズ別の bash スクリプトを生成します。apply と同じ関数でコマンドを組み立てているので、中身がずれることはありません。

```
out/export_20260904_100000_1234/
├── README.txt        生成日時・生成者・生成元 CSV の sha256・config の値・実行順
├── input.csv         生成元 CSV のコピー
├── 01_project.sh     プロジェクト作成・課金・API
├── 02_sa.sh          SA 作成
├── 03_firewall.sh    FW ルール
├── 04_gce.sh         GCE への SA 紐づけ
└── 90_destroy.sh     後片付け（逆順。実行時に yes 入力が必要。--yes で省略）
```

- 各行の前に `# ---- CSV 2 行目: tenant-0001 (テナント0001) ----` のコメントが入るので、Excel の行と突き合わせてレビューできます。
- コマンドは実行時に存在確認をしてから作る形（`exists ... || run ...`）になっています。生成から実行まで時間が空いて状態が変わっていても、そのまま流せます。
- スクリプトを実行すると、同じフォルダに `01_project.<日時>.log` のように**実行した gcloud コマンドと出力がそのまま残ります**。これが実行証跡になります。
- 04_gce.sh は起動中のインスタンスをスキップして失敗に数えます。停止してから再実行してください。
- CSV を直したら export し直してください。古いフォルダの README.txt に sha256 があるので、どの CSV から出したかは後から分かります。

### evidence（証跡取得）

`out/evidence_<日時>/` に、実際の状態を describe で取得して保存し、CSV と config の期待値と突き合わせた結果を出します。参照系しか実行しないので、いつ何度流しても安全です。

```
out/evidence_20260904_110000_1234/
├── run-info.txt      取得日時・取得者・gcloud バージョン・入力 CSV の sha256・config の値
├── input.csv         入力 CSV のコピー
├── summary.md        項目ごとの 期待値 / 実際 / OK・NG の表（そのまま報告書に貼れる）
├── summary.csv       同じ内容の CSV
├── tenant-0001/
│   ├── project.yaml          gcloud projects describe
│   ├── billing.yaml          gcloud billing projects describe
│   ├── services.txt          有効な API の一覧
│   ├── sa.yaml               gcloud iam service-accounts describe
│   ├── sa-iam-policy.yaml    SA の IAM ポリシー（TokenCreator の付与状況）
│   ├── firewall.yaml         gcloud compute firewall-rules describe
│   └── gce_vm-tenant-0001.yaml  gcloud compute instances describe
└── tenant-0002/ ...
```

突き合わせる項目は次のとおりです。1 件でも NG があれば終了コードは 1 です。

| 項目 | 期待値 |
| --- | --- |
| project | lifecycleState が ACTIVE、親が config の PARENT_FOLDER_ID / PARENT_ORG_ID |
| billing | config の BILLING_ACCOUNT_ID に紐づいている |
| apis | ENABLE_APIS が全て有効 |
| sa | SA が存在する |
| sa-iam | GCE を付ける行がある場合、Compute サービスエージェントに TokenCreator が付いている |
| firewall | EGRESS、VPC 名、無効化されていない、target SA、宛先 CIDR、許可ポート が CSV と一致（順序は問わない） |
| gce | インスタンスの SA が CSV の SA。status は参考情報（INFO） |

## 出力

`out/result_<コマンド>_<日時>.csv` に、行・フェーズ・対象ごとに 1 行ずつ結果が入ります。

```
timestamp,line,project_id,phase,target,status,detail
2026-09-04T10:00:01,2,tenant-0001,project,project,CREATED,""
2026-09-04T10:00:20,2,tenant-0001,sa,app-runner@tenant-0001.iam.gserviceaccount.com,CREATED,""
2026-09-04T10:00:25,2,tenant-0001,firewall,egress-tenant-0001,CREATED,"to=10.0.1.0/24 allow=tcp:443"
2026-09-04T10:00:30,3,tenant-0002,gce,asia-northeast1-a/vm-tenant-0002,FAILED,"インスタンスが RUNNING です。停止してから再実行してください: gcloud compute instances stop ..."
```

| status | 意味 |
| --- | --- |
| CREATED / UPDATED / ATTACHED | 作成 / 更新 / GCE に紐づけ |
| EXISTS | 既にあるので何もしていない |
| PLANNED | plan 時。apply すれば実行される |
| SKIPPED | 対象外（gce_instance が空、前フェーズ失敗など） |
| FAILED | 失敗。detail にエラーと対処 |
| DELETED / RESTORED / NOT_FOUND | destroy 時 |

`line` は入力 CSV の行番号（ヘッダーが 1 行目）なので、Excel で該当行をすぐ探せます。gcloud の生の出力は `out/<コマンド>_<日時>.log` にあります。

## 動作の細かい点

- SA は作成直後に参照できないことがあるため、見えるようになるまで最大 `WAIT_SECONDS` 秒待ってから次に進みます。
- レート制限や「作成中」系のエラーは `RETRY_MAX` 回まで間隔を広げて再試行します。
- FW ルール名は `<FW_RULE_PREFIX>-<project_id>`（例: `egress-tenant-0001`）で、`--direction=EGRESS --action=ALLOW` 固定です。
- GCE への紐づけは `set-service-account` で、スコープは `SA_SCOPES`（既定 `cloud-platform`）を付けます。
- 実行順はフェーズ単位です（全行の project → 全行の sa → …）。作成直後の待ち時間をまとめて吸収するためです。
- export したスクリプトは `provision.sh` に依存せず、gcloud だけあれば動きます。Cloud Shell にそのフォルダを持ち込んで実行できます。

## トラブルシュート

| 症状 | 対処 |
| --- | --- |
| `CSV が UTF-8 ではありません` | Excel の保存形式を「CSV UTF-8 (コンマ区切り)」にする。「CSV (コンマ区切り)」は Shift-JIS |
| `Requested entity already exists` | その project_id は世界のどこかで使われている。別の ID にする |
| gce フェーズで `TokenCreator がありません` | detail に出ている `add-iam-policy-binding` をそのまま実行して `apply --phase gce` |
| gce フェーズで `インスタンスが RUNNING です` | detail のコマンドで停止してから `apply --phase gce`。付け替え後の起動は手動 |
| `Cross-project service account is not allowed` | 組織ポリシー `iam.disableCrossProjectServiceAccountUsage` が有効。親フォルダで解除する |
| 課金の紐づけで失敗 | 課金アカウントに `roles/billing.user` があるか、課金アカウントのプロジェクト数上限に達していないかを確認 |
