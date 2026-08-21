.PHONY: help \
	lock \
	check whoami myip tools \
	bootstrap-init bootstrap-plan bootstrap-apply bootstrap-output backend \
	init reinit plan apply destroy output \
	setup url creds exec logs status events instances tasks diag recycle \
	fmt validate clean

# ==============================================================================
# 設定
# ==============================================================================

BOOTSTRAP_DIR := bootstrap
ECS_DIR       := ecs
BACKEND_FILE  := $(ECS_DIR)/backend.hcl

LOG_SINCE     ?= 10m

# aws CLI を使うターゲット（status / logs / setup / creds / exec）のために、
# ecs/terraform.tfvars の aws_profile を AWS_PROFILE として引き継ぐ。
#
# terraform は tfvars を直接読むので不要ですが、aws CLI は環境変数か --profile しか
# 見ないため、ここで橋渡ししています。環境変数が既に設定されていればそちらが優先です。
TFVARS_PROFILE := $(shell sed -n 's/^[[:space:]]*aws_profile[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(ECS_DIR)/terraform.tfvars 2>/dev/null | head -1)
AWS_PROFILE    ?= $(TFVARS_PROFILE)

ifneq ($(strip $(AWS_PROFILE)),)
export AWS_PROFILE
endif

# .terraform.lock.hcl に入れるプラットフォーム。
# devcontainer（Linux）と Windows ホストの両方で terraform を動かす場合に必要です。
TF_PLATFORMS  ?= linux_amd64 linux_arm64 windows_amd64 darwin_arm64

# ==============================================================================
# [check] 事前確認
# ==============================================================================

check: tools whoami ## [check] ツール・認証・IP をまとめて確認
	@echo ""
	@echo "--- アクセス元 IP（allowed_cidrs に入れる値） ---"
	@printf '  %s/32\n' "$$(curl -s https://checkip.amazonaws.com)"
	@echo ""
	@echo "--- 設定ファイル ---"
	@test -f $(BOOTSTRAP_DIR)/terraform.tfvars && echo "  OK  $(BOOTSTRAP_DIR)/terraform.tfvars" || echo "  NG  $(BOOTSTRAP_DIR)/terraform.tfvars がありません（.example をコピー）"
	@test -f $(ECS_DIR)/terraform.tfvars       && echo "  OK  $(ECS_DIR)/terraform.tfvars"       || echo "  NG  $(ECS_DIR)/terraform.tfvars がありません（.example をコピー）"
	@test -f $(BACKEND_FILE)                   && echo "  OK  $(BACKEND_FILE)"                   || echo "  --  $(BACKEND_FILE) は bootstrap-apply で自動生成されます"

tools: ## [check] ツールのバージョンを表示
	@echo "--- ツール ---"
	@for c in terraform aws session-manager-plugin; do \
		if command -v $$c >/dev/null 2>&1; then \
			printf '  %-24s %s\n' "$$c" "$$($$c --version 2>&1 | head -1)"; \
		else \
			printf '  %-24s NOT FOUND\n' "$$c"; \
		fi; \
	done

whoami: ## [check] 現在の AWS 認証情報を表示
	@echo "--- 認証 ---"
ifeq ($(strip $(AWS_PROFILE)),)
	@echo "  AWS_PROFILE = (未解決)"
	@echo "  NG  ecs/terraform.tfvars に aws_profile を書くか、export AWS_PROFILE=<名前> してください"
else
	@printf '  AWS_PROFILE = %s\n' "$(AWS_PROFILE)"
	@aws sts get-caller-identity --output table 2>&1 | sed 's/^/  /' || \
		echo "  NG  認証できません。aws sso login --sso-session <セッション名> --no-browser"
endif

myip: ## [check] アクセス元のグローバル IP を表示
	@printf '%s/32\n' "$$(curl -s https://checkip.amazonaws.com)"

# ==============================================================================
# [bootstrap] tfstate の置き場（アカウントごとに1回）
# ==============================================================================

bootstrap-init: ## [bootstrap] 初期化
	cd $(BOOTSTRAP_DIR) && terraform init

# init を前提にしておく。プロバイダ追加時に "apply だけ実行して失敗" を防ぐため
# （terraform init は冪等なので、変更がなければすぐ終わります）
bootstrap-plan: bootstrap-init ## [bootstrap] 変更確認
	cd $(BOOTSTRAP_DIR) && terraform plan

bootstrap-apply: bootstrap-init ## [bootstrap] 適用（ecs/backend.hcl も自動生成される）
	cd $(BOOTSTRAP_DIR) && terraform apply
	@echo ""
	@echo "--- 生成された $(BACKEND_FILE) ---"
	@cat $(BACKEND_FILE)

bootstrap-output: ## [bootstrap] output を表示
	cd $(BOOTSTRAP_DIR) && terraform output

backend: ## [bootstrap] backend.hcl を手動で再生成（通常は不要）
	cd $(BOOTSTRAP_DIR) && terraform output -raw backend_config > ../$(BACKEND_FILE)
	@echo "generated: $(BACKEND_FILE)"
	@cat $(BACKEND_FILE)

# ==============================================================================
# [terraform] 本体
# ==============================================================================

init: ## [terraform] 初期化（backend.hcl を使用）
	@test -f $(BACKEND_FILE) || { \
		echo "ERROR: $(BACKEND_FILE) がありません。先に 'make bootstrap-apply' を実行してください。"; \
		exit 1; \
	}
	cd $(ECS_DIR) && terraform init -backend-config=backend.hcl

reinit: ## [terraform] バックエンド設定が変わったときの再初期化（state 移行の確認を出さない）
	@test -f $(BACKEND_FILE) || { \
		echo "ERROR: $(BACKEND_FILE) がありません。先に 'make bootstrap-apply' を実行してください。"; \
		exit 1; \
	}
	cd $(ECS_DIR) && terraform init -reconfigure -backend-config=backend.hcl

plan: init ## [terraform] 変更確認
	cd $(ECS_DIR) && terraform plan

apply: init ## [terraform] 適用（初回は 25〜35 分かかります）
	cd $(ECS_DIR) && terraform apply

destroy: ## [terraform] 削除（prevent_destroy のリソースは残ります）
	cd $(ECS_DIR) && terraform destroy

output: ## [terraform] output を表示
	cd $(ECS_DIR) && terraform output

# ==============================================================================
# [forge] 構築後の操作
# ==============================================================================

setup: ## [forge] 初期セットアップ（管理者作成 + ランナー登録）を1回だけ実行
	@echo "forge が Running=1 になってから実行してください。"
	@echo "（runner はこの setup で forge 側に登録されるため、実行前は Running=0 が正常です）"
	cd $(ECS_DIR) && eval "$$(terraform output -raw bootstrap_command)"
	@echo ""
	@echo "進捗は 'make logs' で確認してください（bootstrap-done が出れば成功）。"

url: ## [forge] アクセス URL を表示
	@cd $(ECS_DIR) && terraform output -raw forge_url && echo ""

creds: ## [forge] 初期管理者のログイン情報を表示
	@cd $(ECS_DIR) && sh -c "$$(terraform output -raw admin_credentials_command)"

exec: ## [forge] Forgejo コンテナに入る（SSH 鍵不要）
	cd $(ECS_DIR) && eval "$$(terraform output -raw exec_command)"

logs: ## [forge] ログを追う（LOG_SINCE=10m で変更可）
	aws logs tail "$$(cd $(ECS_DIR) && terraform output -raw log_group)" \
		--since $(LOG_SINCE) --follow

status: ## [forge] ECS サービスの状態を表示
	@cd $(ECS_DIR) && \
		cluster="$$(terraform output -raw cluster_name)"; \
		services="$$(terraform output -json service_names | tr -d '[]"' | tr ',' ' ')"; \
		aws ecs describe-services --cluster "$$cluster" --services $$services \
			--query 'services[].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount}' \
			--output table

events: ## [forge] サービスのイベントを表示（タスクが配置できない理由はここに出る）
	@cd $(ECS_DIR) && \
		cluster="$$(terraform output -raw cluster_name)"; \
		for s in $$(terraform output -json service_names | tr -d '[]"' | tr ',' ' '); do \
			echo "--- $$s ---"; \
			aws ecs describe-services --cluster "$$cluster" --services "$$s" \
				--query 'services[0].events[:10].[createdAt,message]' --output text; \
			echo ""; \
		done

instances: ## [forge] クラスタに登録されているインスタンスを表示
	@cd $(ECS_DIR) && \
		cluster="$$(terraform output -raw cluster_name)"; \
		echo "--- クラスタのキャパシティプロバイダ ---"; \
		aws ecs describe-clusters --clusters "$$cluster" \
			--query 'clusters[0].capacityProviders' --output text; \
		echo ""; \
		echo "--- 登録インスタンス ---"; \
		arns="$$(aws ecs list-container-instances --cluster "$$cluster" --query 'containerInstanceArns' --output text)"; \
		if [ -z "$$arns" ] || [ "$$arns" = "None" ]; then \
			echo "  0 台。Managed Instances がまだ起動していないか、起動に失敗しています。"; \
		else \
			aws ecs describe-container-instances --cluster "$$cluster" --container-instances $$arns \
				--query 'containerInstances[].{Id:ec2InstanceId,Status:status,Agent:agentConnected,Running:runningTasksCount}' \
				--output table; \
		fi

tasks: ## [forge] タスクの状態と停止理由を表示
	@cd $(ECS_DIR) && \
		cluster="$$(terraform output -raw cluster_name)"; \
		for st in RUNNING STOPPED; do \
			echo "--- $$st ---"; \
			arns="$$(aws ecs list-tasks --cluster "$$cluster" --desired-status $$st --query 'taskArns' --output text)"; \
			if [ -z "$$arns" ] || [ "$$arns" = "None" ]; then echo "  なし"; else \
				aws ecs describe-tasks --cluster "$$cluster" --tasks $$arns \
					--query 'tasks[].{Def:taskDefinitionArn,Last:lastStatus,StopCode:stopCode,Reason:stoppedReason}' \
					--output table; \
			fi; \
			echo ""; \
		done

diag: status instances events tasks ## [forge] 上記4つをまとめて実行

recycle: ## [forge] インスタンスを入れ替える（インスタンス要件の変更を即時反映させたいとき）
	@cd $(ECS_DIR) && \
		cluster="$$(terraform output -raw cluster_name)"; \
		arns="$$(aws ecs list-container-instances --cluster "$$cluster" --query 'containerInstanceArns' --output text)"; \
		if [ -z "$$arns" ] || [ "$$arns" = "None" ]; then echo "インスタンスが登録されていません。"; exit 1; fi; \
		ec2="$$(aws ecs describe-container-instances --cluster "$$cluster" --container-instances $$arns \
			--query 'containerInstances[].ec2InstanceId' --output text)"; \
		echo "対象: $$ec2"; \
		echo "終了させると Managed Instances が新しい要件で作り直します。"; \
		echo "リポジトリは EFS、メタデータは RDS、成果物は S3 にあるのでデータは失われません。"; \
		echo "ただしタスク再配置の間、数分アクセスできなくなります。"; \
		printf '入れ替えますか？ [y/N] '; read ans; \
		[ "$$ans" = "y" ] || { echo "中止しました。"; exit 1; }; \
		aws ec2 terminate-instances --instance-ids $$ec2 \
			--query 'TerminatingInstances[].{Id:InstanceId,State:CurrentState.Name}' --output table; \
		echo ""; \
		echo "数分後に 'make instances' で新しいインスタンスを確認してください。"

# ==============================================================================
# [dev] 開発用
# ==============================================================================

lock: ## [dev] .terraform.lock.hcl を複数プラットフォーム分で再生成
	cd $(BOOTSTRAP_DIR) && terraform providers lock $(addprefix -platform=,$(TF_PLATFORMS))
	cd $(ECS_DIR) && terraform providers lock $(addprefix -platform=,$(TF_PLATFORMS))
	@echo ""
	@echo "生成しました（.gitignore 対象なのでコミットは不要です）。"

fmt: ## [dev] Terraform ファイルを整形
	terraform fmt -recursive

validate: ## [dev] 構文チェック（init 済みであること）
	cd $(BOOTSTRAP_DIR) && terraform validate
	cd $(ECS_DIR) && terraform validate

clean: ## [dev] ローカルの作業ファイルを削除（state と backend.hcl は消しません）
	rm -rf $(BOOTSTRAP_DIR)/.terraform $(ECS_DIR)/.terraform
	rm -f $(BOOTSTRAP_DIR)/*.tfplan $(ECS_DIR)/*.tfplan

# ==============================================================================

help: ## このヘルプを表示
	@echo "git-forge-aws — 実行順:"
	@echo "  1. make check            事前確認"
	@echo "  2. make bootstrap-init bootstrap-apply"
	@echo "  3. make init plan"
	@echo "  4. make apply            （25〜35分）"
	@echo "  5. make setup            初期セットアップ"
	@echo "  6. make url creds        アクセス情報"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
