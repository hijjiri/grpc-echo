SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

KUBECTL ?= kubectl
HELM   ?= helm
KIND   ?= kind
DOCKER ?= docker

K8S_NAMESPACE ?= default
KIND_CLUSTER  ?= grpc-echo

# ---------------------------------------------------------
# Safety guard for destructive operations
#   - Set CONFIRM=1 to run targets that delete resources
# ---------------------------------------------------------
CONFIRM ?= 0

# =========================================================
# Images / Tags
#   - TAG は “kind load” と “helm --set global.imageTag” の唯一の基準
#   - デフォルトは git short sha -> fallback は日時
# =========================================================
GRPC_IMAGE_REPO ?= grpc-echo
GW_IMAGE_REPO   ?= grpc-http-gateway
TAG ?= $(shell (git rev-parse --short HEAD 2>/dev/null) || date +%Y%m%d%H%M%S)

# ---------------------------------------------------------
# Helm / Chart (A: global.imageTag 一本化)
# ---------------------------------------------------------
HELM_RELEASE ?= grpc-echo
CHART_DIR    ?= ./helm/grpc-echo

ENV         ?= dev
VALUES_FILE ?= $(CHART_DIR)/values.$(ENV).yaml

# ---------------------------------------------------------
# Proto
# ---------------------------------------------------------
PROTO_DIRS     := $(shell find api -name '*.proto' -exec dirname {} \; | sort -u)
GATEWAY_PROTOS := $(shell find api -name '*.proto' -print)

# ---------------------------------------------------------
# k-logs UX defaults
# ---------------------------------------------------------
APP       ?= grpc-echo
POD       ?=
CONTAINER ?=
TAIL      ?= 200
FOLLOW    ?= 1
SINCE     ?=
PREVIOUS  ?= 0

# ---------------------------------------------------------
# Optional file (local dev etc.)
# - If missing, make will ignore it.
# ---------------------------------------------------------
-include Makefile.local

# =========================================================
# Help
# =========================================================
.PHONY: help
help: ## Show help (main targets first; optional targets are listed after if Makefile.local exists)
	@awk ' \
	BEGIN {FS=":.*## "}; \
	/^##@/ {printf "\n%s\n", substr($$0,5); next} \
	/^[a-zA-Z0-9_.-]+:.*## / {printf "  %-26s %s\n", $$1, $$2} \
	' $(MAKEFILE_LIST)
	@echo ""
	@echo "Common vars:"
	@echo "  ENV=$(ENV)                    (dev|prod)"
	@echo "  VALUES_FILE=$(VALUES_FILE)"
	@echo "  TAG=$(TAG)"
	@echo "  K8S_NAMESPACE=$(K8S_NAMESPACE)"
	@echo "  KIND_CLUSTER=$(KIND_CLUSTER)"
	@echo "  CONFIRM=$(CONFIRM)            (set 1 to run destructive targets)"
	@echo ""

##@ Mainline (golden path)
.PHONY: up pf status logs smoke
up: k-rebuild-wait ## Golden path: build -> kind load -> helm up(wait/atomic) -> rollout -> assert
pf: k-ingress-pf ## Port-forward ingress-nginx controller to localhost:8080 (keep running)
status: k-status ## Show pods/services/ingress (ns=$(K8S_NAMESPACE))
logs: k-logs ## Tail logs (APP=..., ns=$(K8S_NAMESPACE))
smoke: smoke-todos ## Smoke: list todos via ingress (requires 'make pf' running)

# =========================================================
# Protobuf
# =========================================================
.PHONY: proto
proto: ## Generate protobuf (go / go-grpc / grpc-gateway)
	@echo "==> Generating protobufs..."
	@for dir in $(PROTO_DIRS); do \
		echo " -> $$dir"; \
		protoc \
		  -I . \
		  -I third_party \
		  --go_out=paths=source_relative:. \
		  --go-grpc_out=paths=source_relative:. \
		  $$dir/*.proto; \
	done
	@echo "==> Generating gRPC-Gateway..."
	@for file in $(GATEWAY_PROTOS); do \
		echo " -> $$file"; \
		protoc \
		  -I . \
		  -I third_party \
		  --grpc-gateway_out=paths=source_relative,generate_unbound_methods=true:. \
		  $$file; \
	done

# =========================================================
# Helm (tag-safe)
# =========================================================
.PHONY: h-template h-lint h-status h-up h-up-wait h-rollback h-uninstall h-values h-manifest

h-template: ## helm template (ENV=dev|prod, tag=TAG)
	$(HELM) template $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) -f $(VALUES_FILE) \
	  --set global.imageTag=$(TAG)

h-lint: ## helm lint
	$(HELM) lint $(CHART_DIR)

h-status: ## helm status
	$(HELM) status $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-up: ## helm upgrade --install (tag=TAG)
	$(HELM) upgrade --install $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) \
	  -f $(VALUES_FILE) \
	  --set global.imageTag=$(TAG)

h-up-wait: ## helm upgrade --install --wait --timeout 5m --atomic (tag=TAG)
	$(HELM) upgrade --install $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) \
	  -f $(VALUES_FILE) \
	  --set global.imageTag=$(TAG) \
	  --wait --timeout 5m --atomic

h-rollback: ## helm rollback (requires CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then echo "❌ Refusing to run 'h-rollback' without CONFIRM=1"; exit 1; fi
	$(HELM) rollback $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-uninstall: ## helm uninstall (requires CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then echo "❌ Refusing to run 'h-uninstall' without CONFIRM=1"; exit 1; fi
	$(HELM) uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-values: ## helm get values -a
	$(HELM) get values $(HELM_RELEASE) -n $(K8S_NAMESPACE) -a

h-manifest: ## helm get manifest
	$(HELM) get manifest $(HELM_RELEASE) -n $(K8S_NAMESPACE)

# =========================================================
# Kubernetes (observability / ops)
# =========================================================
.PHONY: k-status k-logs k-wait k-image-check k-image-assert k-ingress-pf k-clean

k-status: ## Show pods/services/ingress
	@echo "== Pods =="; $(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide
	@echo ""
	@echo "== Services =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE)
	@echo ""
	@echo "== Ingress =="; $(KUBECTL) get ingress -n $(K8S_NAMESPACE) || true

k-logs: ## Tail logs (default APP=grpc-echo). Options: POD=... CONTAINER=... TAIL=200 FOLLOW=1 SINCE=... PREVIOUS=0
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; \
	follow=""; [ "$(FOLLOW)" = "1" ] && follow="-f"; \
	tail="--tail=$(TAIL)"; \
	since=""; [ -n "$(SINCE)" ] && since="--since=$(SINCE)"; \
	container=""; [ -n "$(CONTAINER)" ] && container="-c $(CONTAINER)"; \
	prev=""; [ "$(PREVIOUS)" = "1" ] && prev="--previous"; \
	if [ -n "$(POD)" ]; then \
	  echo "==> kubectl logs pod/$(POD) -n $$ns"; \
	  $(KUBECTL) logs -n $$ns $$follow $$tail $$since $$container $$prev pod/$(POD); \
	else \
	  echo "==> kubectl logs deploy/$(APP) -n $$ns"; \
	  $(KUBECTL) logs -n $$ns $$follow $$tail $$since $$container $$prev deploy/$(APP); \
	fi

k-wait: ## Wait rollout for grpc-echo and http-gateway
	$(KUBECTL) rollout status deploy/grpc-echo -n $(K8S_NAMESPACE)
	@$(KUBECTL) get deploy http-gateway -n $(K8S_NAMESPACE) >/dev/null 2>&1 && \
	  $(KUBECTL) rollout status deploy/http-gateway -n $(K8S_NAMESPACE) || \
	  echo "skip: deploy/http-gateway not found"

k-image-check: ## Show deployment images
	@echo "grpc-echo image:"
	@$(KUBECTL) get deploy grpc-echo -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
	@echo "http-gateway image:"
	@$(KUBECTL) get deploy http-gateway -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

k-image-assert: ## Assert deployments are running expected tag
	@grpc_img="$$( $(KUBECTL) get deploy grpc-echo -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}' )"; \
	gw_img="$$( $(KUBECTL) get deploy http-gateway -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}' )"; \
	exp_grpc="$(GRPC_IMAGE_REPO):$(TAG)"; \
	exp_gw="$(GW_IMAGE_REPO):$(TAG)"; \
	echo "expect grpc  : $$exp_grpc"; \
	echo "actual grpc  : $$grpc_img"; \
	echo "expect gw    : $$exp_gw"; \
	echo "actual gw    : $$gw_img"; \
	[ "$$grpc_img" = "$$exp_grpc" ] && [ "$$gw_img" = "$$exp_gw" ] && echo "✅ image tag match" || (echo "❌ image tag mismatch" && exit 1)

k-ingress-pf: ## Port-forward ingress-nginx controller to localhost:8080
	$(KUBECTL) port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80

k-clean: ## Delete unhealthy pods (ImagePullBackOff/ErrImagePull/CrashLoopBackOff) in namespace (requires CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then echo "❌ Refusing to run 'k-clean' without CONFIRM=1"; exit 1; fi
	@set -euo pipefail; \
	echo "==> Deleting unhealthy pods in ns=$(K8S_NAMESPACE)"; \
	pods="$$( $(KUBECTL) get pods -n $(K8S_NAMESPACE) --no-headers 2>/dev/null | \
	  awk '$$3=="ImagePullBackOff" || $$3=="ErrImagePull" || $$3=="CrashLoopBackOff" {print $$1}' )"; \
	if [ -z "$$pods" ]; then \
	  echo "No unhealthy pods found."; \
	else \
	  echo "$$pods" | xargs -r $(KUBECTL) delete pod -n $(K8S_NAMESPACE); \
	fi

# =========================================================
# kind rebuild (tag-safe end-to-end)
# =========================================================
.PHONY: k-kind-assert
k-kind-assert: ## Assert kind cluster exists
	@set -euo pipefail; \
	if ! $(KIND) get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
	  echo "❌ kind cluster '$(KIND_CLUSTER)' not found. Create it first (e.g. kind create cluster --name $(KIND_CLUSTER))."; \
	  exit 1; \
	fi

.PHONY: k-load-grpc k-load-gw k-load k-rebuild-wait

k-load-grpc: k-kind-assert ## docker build grpc-echo:TAG -> kind load
	$(DOCKER) build -t $(GRPC_IMAGE_REPO):$(TAG) .
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GRPC_IMAGE_REPO):$(TAG)

k-load-gw: k-kind-assert ## docker build grpc-http-gateway:TAG -> kind load
	$(DOCKER) build -f Dockerfile.http_gateway -t $(GW_IMAGE_REPO):$(TAG) .
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GW_IMAGE_REPO):$(TAG)

k-load: k-load-grpc k-load-gw ## Build both images and kind load both (tag=TAG)

k-rebuild-wait: k-load h-up-wait k-wait k-image-assert k-status ## Build->kind load->helm up(wait/atomic)->rollout->assert->status
	@echo "✅ Deployed with TAG=$(TAG) (ENV=$(ENV))"

# =========================================================
# Smoke tests (Ingress port-forward assumed: make k-ingress-pf)
# =========================================================
.PHONY: smoke-login smoke-todos

smoke-login: ## Smoke: login via ingress and print token (requires k-ingress-pf running)
	@echo "==> POST http://grpc-echo.local:8080/auth/login"
	@resp=$$(curl -sS http://grpc-echo.local:8080/auth/login \
	  -H "Content-Type: application/json" \
	  -d '{"username":"user-123","password":"password"}'); \
	echo "$$resp"; \
	if command -v jq >/dev/null 2>&1; then \
	  echo "$$resp" | jq -r '.accessToken'; \
	else \
	  echo "$$resp" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'; \
	fi

smoke-todos: ## Smoke: list todos via ingress (auto token)
	@echo "==> GET http://grpc-echo.local:8080/v1/todos"
	@token="$${TOKEN:-}"; \
	if [ -z "$$token" ]; then \
	  resp=$$(curl -sS http://grpc-echo.local:8080/auth/login \
	    -H "Content-Type: application/json" \
	    -d '{"username":"user-123","password":"password"}'); \
	  if command -v jq >/dev/null 2>&1; then \
	    token=$$(echo "$$resp" | jq -r '.accessToken'); \
	  else \
	    token=$$(echo "$$resp" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'); \
	  fi; \
	fi; \
	curl -sS http://grpc-echo.local:8080/v1/todos \
	  -H "Authorization: Bearer $$token" | (command -v jq >/dev/null 2>&1 && jq . || cat); \
	echo ""

# =========================================================
# MySQL (helm/mysql chart)
# =========================================================
##@ MySQL (helm/mysql chart)
MYSQL_CHART_DIR ?= ./helm/mysql
MYSQL_RELEASE   ?= mysql
MYSQL_POD       ?= mysql-0
MYSQL_DB        ?= grpcdb
MYSQL_DUMP      ?= /tmp/grpcdb.sql

.PHONY: mysql-up-wait mysql-status mysql-logs mysql-wait mysql-root-pass mysql-exec mysql-init-check mysql-backup mysql-restore mysql-uninstall mysql-pvc mysql-pvc-delete mysql-reinstall

mysql-up-wait: ## helm upgrade --install MySQL (./helm/mysql) --wait --timeout 10m --atomic
	$(HELM) upgrade --install $(MYSQL_RELEASE) $(MYSQL_CHART_DIR) -n $(K8S_NAMESPACE) \
	  --wait --timeout 10m --atomic

mysql-status: ## Show mysql sts/pod/svc/pvc
	@$(KUBECTL) get sts,pod,svc,pvc -n $(K8S_NAMESPACE) | egrep -n 'mysql|NAME' || true

mysql-logs: ## Tail mysql logs
	$(KUBECTL) logs -n $(K8S_NAMESPACE) -f sts/$(MYSQL_RELEASE) -c mysql --tail=200

mysql-wait: ## Wait mysql pod ready (StatefulSet rollout)
	$(KUBECTL) rollout status -n $(K8S_NAMESPACE) sts/$(MYSQL_RELEASE) --timeout=10m

mysql-root-pass: ## Print root password from secret (local output)
	@$(KUBECTL) get secret -n $(K8S_NAMESPACE) $(MYSQL_RELEASE) -o jsonpath='{.data.mysql-root-password}' | base64 -d; echo

mysql-exec: ## Exec into mysql pod (bash/sh)
	$(KUBECTL) exec -n $(K8S_NAMESPACE) -it $(MYSQL_POD) -- sh

mysql-init-check: ## Check schema/table count inside mysql (uses MYSQL_ROOT_PASSWORD env in pod)
	@$(KUBECTL) exec -n $(K8S_NAMESPACE) -it $(MYSQL_POD) -- sh -lc \
	  'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" -e "USE $(MYSQL_DB); SHOW TABLES; SELECT COUNT(*) FROM todos;"'

mysql-backup: ## mysqldump grpcdb from pod -> MYSQL_DUMP (local file)
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; out="$(MYSQL_DUMP)"; \
	echo "==> mysqldump $(MYSQL_DB) from $(MYSQL_POD) -> $$out"; \
	$(KUBECTL) exec -n $$ns $(MYSQL_POD) -- sh -lc 'mysqldump -uroot -p"$$MYSQL_ROOT_PASSWORD" $(MYSQL_DB)' > "$$out"; \
	ls -lh "$$out"; tail -n 3 "$$out" || true

mysql-restore: ## Restore MYSQL_DUMP (local file) -> mysql pod (grpcdb)
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; in="$(MYSQL_DUMP)"; \
	[ -f "$$in" ] || (echo "❌ dump not found: $$in"; exit 1); \
	echo "==> restore $$in -> $(MYSQL_POD) db=$(MYSQL_DB)"; \
	$(KUBECTL) exec -n $$ns -i $(MYSQL_POD) -- sh -lc 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" $(MYSQL_DB)' < "$$in"; \
	echo "✅ restore done"

mysql-pvc: ## List PVCs for mysql (StatefulSet volumeClaimTemplates)
	@$(KUBECTL) get pvc -n $(K8S_NAMESPACE) | grep -E 'data-$(MYSQL_RELEASE)-' || echo "NO PVC"

mysql-pvc-delete: ## Delete MySQL PVCs (DANGEROUS) requires CONFIRM=1
	@if [ "$(CONFIRM)" != "1" ]; then echo "❌ Refusing to run 'mysql-pvc-delete' without CONFIRM=1"; exit 1; fi
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; \
	pvcs="$$( $(KUBECTL) get pvc -n $$ns -o name | grep '^persistentvolumeclaim/data-$(MYSQL_RELEASE)-' || true )"; \
	if [ -z "$$pvcs" ]; then echo "No PVC found."; exit 0; fi; \
	echo "==> deleting PVCs:"; echo "$$pvcs"; \
	echo "$$pvcs" | xargs -r $(KUBECTL) delete -n $$ns

mysql-uninstall: ## helm uninstall mysql (requires CONFIRM=1). NOTE: PVC is NOT deleted by default.
	@if [ "$(CONFIRM)" != "1" ]; then echo "❌ Refusing to run 'mysql-uninstall' without CONFIRM=1"; exit 1; fi
	$(HELM) uninstall $(MYSQL_RELEASE) -n $(K8S_NAMESPACE)

mysql-reinstall: mysql-uninstall mysql-up-wait ## Reinstall mysql (keeps PVC by default; requires CONFIRM=1)
	@echo "✅ reinstalled mysql (PVC kept unless you ran make mysql-pvc-delete)"
