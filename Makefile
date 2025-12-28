SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

KUBECTL ?= kubectl
HELM   ?= helm
KIND   ?= kind
DOCKER ?= docker

K8S_NAMESPACE ?= default
KIND_CLUSTER  ?= grpc-echo

# Expected kube context for kind
K8S_CONTEXT_EXPECT ?= kind-$(KIND_CLUSTER)
ALLOW_OTHER_CONTEXT ?= 0

# =========================================================
# Images / Tags
#   - TAG is the single source of truth for:
#       docker tag -> kind load -> helm --set global.imageTag
# =========================================================
GRPC_IMAGE_REPO ?= grpc-echo
GW_IMAGE_REPO   ?= grpc-http-gateway
TAG ?= $(shell (git rev-parse --short HEAD 2>/dev/null) || date +%Y%m%d%H%M%S)

# ---------------------------------------------------------
# Helm / Chart (App)
# ---------------------------------------------------------
HELM_RELEASE ?= grpc-echo
CHART_DIR    ?= ./helm/grpc-echo

ENV         ?= dev
VALUES_FILE ?= $(CHART_DIR)/values.$(ENV).yaml

# ---------------------------------------------------------
# Proto
# ---------------------------------------------------------
PROTOC ?= protoc
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
# Optional local overrides/targets
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
	@echo "  K8S_CONTEXT_EXPECT=$(K8S_CONTEXT_EXPECT) (ALLOW_OTHER_CONTEXT=$(ALLOW_OTHER_CONTEXT))"
	@echo ""

# =========================================================
##@ Main: Golden Path
# =========================================================
.PHONY: gp preflight guard-context context diag sot-audit sot-assert check-values

gp: preflight check-values mysql-up-wait k-rebuild-wait ## Golden path: mysql -> build/load -> helm up(wait/atomic) -> rollout -> assert
	@echo ""
	@echo "Next steps:"
	@echo "  1) In another terminal: make k-ingress-pf"
	@echo "  2) Then:                make smoke"
	@echo ""

preflight: guard-context ## Preflight checks (tools + kube context)
	@set -euo pipefail; \
	for c in $(KUBECTL) $(HELM) $(KIND) $(DOCKER); do \
	  command -v $$c >/dev/null 2>&1 || (echo "❌ missing command: $$c" && exit 1); \
	done; \
	echo "✅ tools OK"; \
	echo "kubectl context: $$($(KUBECTL) config current-context 2>/dev/null || echo '<none>')"; \
	echo "namespace      : $(K8S_NAMESPACE)"

check-values: ## Check ENV/VALUES_FILE exists
	@set -euo pipefail; \
	test -f "$(VALUES_FILE)" || (echo "❌ values file not found: $(VALUES_FILE) (ENV=$(ENV))" && exit 1)

guard-context: ## Guard: verify kubectl context (set ALLOW_OTHER_CONTEXT=1 to bypass)
	@set -euo pipefail; \
	ctx="$$( $(KUBECTL) config current-context 2>/dev/null || true )"; \
	exp="$(K8S_CONTEXT_EXPECT)"; \
	if [ "$(ALLOW_OTHER_CONTEXT)" = "1" ] || [ -z "$$exp" ]; then exit 0; fi; \
	if [ "$$ctx" != "$$exp" ]; then \
	  echo "❌ Refusing: kubectl context is '$$ctx' but expected '$$exp'"; \
	  echo "   If you know what you're doing, run with ALLOW_OTHER_CONTEXT=1"; \
	  exit 1; \
	fi

context: ## Show current kubectl context + ns + nodes
	@$(MAKE) --no-print-directory guard-context
	@echo "context: $$($(KUBECTL) config current-context)"; \
	echo "ns     : $(K8S_NAMESPACE)"; \
	echo ""; \
	$(KUBECTL) get nodes -o wide

diag: ## Quick diagnostics bundle (context/status/events/helm)
	@$(MAKE) --no-print-directory context
	@echo ""
	@$(MAKE) --no-print-directory k-status
	@echo ""
	@$(MAKE) --no-print-directory k-events
	@echo ""
	@$(MAKE) --no-print-directory h-status || true
	@$(MAKE) --no-print-directory mysql-status || true

sot-audit: ## Audit helm-managed labels/annotations for key app resources
	@$(MAKE) --no-print-directory guard-context
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; \
	for r in \
	  deploy/grpc-echo deploy/http-gateway \
	  svc/grpc-echo svc/http-gateway \
	  ingress/http-gateway \
	  cm/grpc-echo-config secret/grpc-echo-secret \
	; do \
	  if $(KUBECTL) get $$r -n $$ns >/dev/null 2>&1; then \
	    mb="$$( $(KUBECTL) get $$r -n $$ns -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null )"; \
	    rel="$$( $(KUBECTL) get $$r -n $$ns -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null )"; \
	    printf "%-26s managed-by=%-6s release=%s\n" "$$r" "$${mb:-<none>}" "$${rel:-<none>}"; \
	  else \
	    printf "%-26s (not found)\n" "$$r"; \
	  fi; \
	done

sot-assert: ## Assert app resources are Helm-managed (fail if SoT looks broken)
	@$(MAKE) --no-print-directory guard-context
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; \
	bad=0; \
	for r in deploy/grpc-echo deploy/http-gateway svc/grpc-echo svc/http-gateway ingress/http-gateway; do \
	  if $(KUBECTL) get $$r -n $$ns >/dev/null 2>&1; then \
	    mb="$$( $(KUBECTL) get $$r -n $$ns -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null )"; \
	    rel="$$( $(KUBECTL) get $$r -n $$ns -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null )"; \
	    if [ "$$mb" != "Helm" ] || [ "$$rel" != "$(HELM_RELEASE)" ]; then \
	      echo "❌ SoT mismatch: $$r managed-by=$${mb:-<none>} release=$${rel:-<none>} (expected Helm/$(HELM_RELEASE))"; \
	      bad=1; \
	    fi; \
	  fi; \
	done; \
	[ $$bad -eq 0 ] && echo "✅ SoT looks good (Helm-managed)"

# =========================================================
# Protobuf
# =========================================================
.PHONY: proto proto-preflight
proto-preflight: ## Check protoc + plugins exist
	@set -euo pipefail; \
	command -v $(PROTOC) >/dev/null 2>&1 || (echo "❌ missing command: $(PROTOC)" && exit 1); \
	command -v protoc-gen-go >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-go (go install google.golang.org/protobuf/cmd/protoc-gen-go@latest)" && exit 1); \
	command -v protoc-gen-go-grpc >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-go-grpc (go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest)" && exit 1); \
	command -v protoc-gen-grpc-gateway >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-grpc-gateway (go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway@latest)" && exit 1); \
	echo "✅ protoc tools OK"

proto: proto-preflight ## Generate protobuf (go / go-grpc / grpc-gateway)
	@echo "==> Generating protobufs..."
	@for dir in $(PROTO_DIRS); do \
		echo " -> $$dir"; \
		$(PROTOC) \
		  -I . \
		  -I third_party \
		  --go_out=paths=source_relative:. \
		  --go-grpc_out=paths=source_relative:. \
		  $$dir/*.proto; \
	done
	@echo "==> Generating gRPC-Gateway..."
	@for file in $(GATEWAY_PROTOS); do \
		echo " -> $$file"; \
		$(PROTOC) \
		  -I . \
		  -I third_party \
		  --grpc-gateway_out=paths=source_relative,generate_unbound_methods=true:. \
		  $$file; \
	done

# =========================================================
##@ Main: Helm (App) - tag-safe
# =========================================================
.PHONY: h-template h-lint h-status h-up h-up-wait h-rollback h-uninstall h-values h-manifest

h-template: check-values ## helm template (ENV=dev|prod, tag=TAG)
	$(HELM) template $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) -f $(VALUES_FILE) \
	  --set global.imageTag=$(TAG)

h-lint: ## helm lint
	$(HELM) lint $(CHART_DIR)

h-status: ## helm status
	@$(MAKE) --no-print-directory guard-context
	$(HELM) status $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-up: check-values ## helm upgrade --install (tag=TAG)
	@$(MAKE) --no-print-directory guard-context
	$(HELM) upgrade --install $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) \
	  -f $(VALUES_FILE) \
	  --set global.imageTag=$(TAG)

h-up-wait: check-values ## helm upgrade --install --wait --timeout 5m --atomic (tag=TAG)
	@$(MAKE) --no-print-directory guard-context
	$(HELM) upgrade --install $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) \
	  -f $(VALUES_FILE) \
	  --set global.imageTag=$(TAG) \
	  --wait --timeout 5m --atomic

h-rollback: ## helm rollback
	@$(MAKE) --no-print-directory guard-context
	$(HELM) rollback $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-uninstall: ## helm uninstall (DANGEROUS) [CONFIRM=1]
	@$(MAKE) --no-print-directory guard-context
	@if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
	$(HELM) uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-values: ## helm get values -a
	@$(MAKE) --no-print-directory guard-context
	$(HELM) get values $(HELM_RELEASE) -n $(K8S_NAMESPACE) -a

h-manifest: ## helm get manifest
	@$(MAKE) --no-print-directory guard-context
	$(HELM) get manifest $(HELM_RELEASE) -n $(K8S_NAMESPACE)

# =========================================================
##@ Main: Kubernetes (ops)
# =========================================================
.PHONY: k-status k-logs k-wait k-image-check k-image-assert k-ingress-pf k-clean k-events k-describe

k-status: ## Show pods/services/ingress
	@$(MAKE) --no-print-directory guard-context
	@echo "== Pods =="; $(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide
	@echo ""
	@echo "== Services =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE)
	@echo ""
	@echo "== Ingress =="; $(KUBECTL) get ingress -n $(K8S_NAMESPACE) || true

k-events: ## Show recent events (sorted)
	@$(MAKE) --no-print-directory guard-context
	@$(KUBECTL) get events -n $(K8S_NAMESPACE) --sort-by=.lastTimestamp | tail -n 50 || true

k-describe: ## Describe key pods (grpc-echo/http-gateway/mysql-0)
	@$(MAKE) --no-print-directory guard-context
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; \
	for p in $$( $(KUBECTL) get pod -n $$ns -o name | egrep 'grpc-echo-|http-gateway-|mysql-0' || true ); do \
	  echo "===== describe $$p ====="; \
	  $(KUBECTL) describe -n $$ns $$p | sed -n '/^Name:/,/^Events:/p'; \
	  echo ""; \
	done

k-logs: ## Tail logs (default APP=grpc-echo). Options: POD=... CONTAINER=... TAIL=200 FOLLOW=1 SINCE=... PREVIOUS=0
	@$(MAKE) --no-print-directory guard-context
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
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) rollout status deploy/grpc-echo -n $(K8S_NAMESPACE)
	$(KUBECTL) rollout status deploy/http-gateway -n $(K8S_NAMESPACE)

k-image-check: ## Show deployment images
	@$(MAKE) --no-print-directory guard-context
	@echo "grpc-echo image:"
	@$(KUBECTL) get deploy grpc-echo -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
	@echo "http-gateway image:"
	@$(KUBECTL) get deploy http-gateway -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

k-image-assert: ## Assert deployments are running expected tag (TAG=...)
	@$(MAKE) --no-print-directory guard-context
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
	@$(MAKE) --no-print-directory guard-context
	@$(KUBECTL) get svc -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1 || \
	  (echo "❌ ingress-nginx-controller not found. Install ingress-nginx first." && exit 1)
	$(KUBECTL) port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80

k-clean: ## Delete unhealthy pods (ImagePullBackOff/ErrImagePull/CrashLoopBackOff) in namespace
	@$(MAKE) --no-print-directory guard-context
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
##@ Main: kind rebuild (tag-safe end-to-end)
# =========================================================
.PHONY: k-load-grpc k-load-gw k-load k-rebuild-wait

k-load-grpc: ## docker build grpc-echo:TAG -> kind load
	$(DOCKER) build -t $(GRPC_IMAGE_REPO):$(TAG) .
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GRPC_IMAGE_REPO):$(TAG)

k-load-gw: ## docker build grpc-http-gateway:TAG -> kind load
	$(DOCKER) build -f Dockerfile.http_gateway -t $(GW_IMAGE_REPO):$(TAG) .
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GW_IMAGE_REPO):$(TAG)

k-load: k-load-grpc k-load-gw ## Build both images and kind load both (TAG=...)

k-rebuild-wait: k-load h-up-wait k-wait k-image-assert sot-assert k-status ## Build->kind load->helm up(wait/atomic)->rollout->assert->status
	@echo "✅ Deployed with TAG=$(TAG) (ENV=$(ENV))"

# =========================================================
##@ Main: Smoke tests (Ingress port-forward assumed: make k-ingress-pf)
# =========================================================
.PHONY: smoke smoke-login smoke-todos

smoke-login: ## Smoke: login via ingress and print token (requires k-ingress-pf running)
	@echo "==> POST http://grpc-echo.local:8080/auth/login"
	@resp=$$(curl -sS http://grpc-echo.local:8080/auth/login \
	  -H "Content-Type: application/json" \
	  -d '{"username":"user-123","password":"password"}' || true); \
	if [ -z "$$resp" ]; then \
	  echo "❌ request failed. Is port-forward running? (run: make k-ingress-pf)"; exit 1; \
	fi; \
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
	    -d '{"username":"user-123","password":"password"}' || true); \
	  if [ -z "$$resp" ]; then \
	    echo "❌ request failed. Is port-forward running? (run: make k-ingress-pf)"; exit 1; \
	  fi; \
	  if command -v jq >/dev/null 2>&1; then \
	    token=$$(echo "$$resp" | jq -r '.accessToken'); \
	  else \
	    token=$$(echo "$$resp" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'); \
	  fi; \
	fi; \
	curl -sS http://grpc-echo.local:8080/v1/todos \
	  -H "Authorization: Bearer $$token" | (command -v jq >/dev/null 2>&1 && jq . || cat); \
	echo ""

smoke: smoke-todos ## Smoke: login + list todos via ingress (requires k-ingress-pf running)

# =========================================================
##@ Main: MySQL (Helm)
# - mysql is a separate Helm release (SoT is Helm)
# =========================================================
.PHONY: mysql-up mysql-up-wait mysql-status mysql-logs mysql-wait mysql-shell mysql-init-check mysql-backup mysql-restore mysql-uninstall mysql-wipe

MYSQL_RELEASE    ?= mysql
MYSQL_CHART_DIR  ?= ./helm/mysql
MYSQL_DB         ?= grpcdb
MYSQL_POD        ?= mysql-0
MYSQL_DUMP       ?= /tmp/grpcdb.sql

mysql-up: ## Deploy mysql (no wait)
	@$(MAKE) --no-print-directory guard-context
	$(HELM) upgrade --install $(MYSQL_RELEASE) $(MYSQL_CHART_DIR) -n $(K8S_NAMESPACE)

mysql-up-wait: ## Deploy mysql (wait/atomic)
	@$(MAKE) --no-print-directory guard-context
	$(HELM) upgrade --install $(MYSQL_RELEASE) $(MYSQL_CHART_DIR) -n $(K8S_NAMESPACE) \
	  --wait --timeout 10m --atomic

mysql-wait: ## Wait mysql StatefulSet rollout
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) rollout status sts/$(MYSQL_RELEASE) -n $(K8S_NAMESPACE) --timeout=10m

mysql-status: ## Show mysql resources (sts/pod/svc/pvc)
	@$(MAKE) --no-print-directory guard-context
	@$(KUBECTL) get sts,pod,svc,pvc -n $(K8S_NAMESPACE) | egrep -n 'NAME|$(MYSQL_RELEASE)|data-$(MYSQL_RELEASE)' || true

mysql-logs: ## Tail mysql logs (sts/mysql)
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) logs -n $(K8S_NAMESPACE) -f sts/$(MYSQL_RELEASE) --tail=200

mysql-shell: ## Exec mysql client in mysql-0 (root)
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) exec -n $(K8S_NAMESPACE) -it $(MYSQL_POD) -- sh -lc 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD"'

mysql-init-check: ## Check init.sql applied (SHOW TABLES in grpcdb)
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) exec -n $(K8S_NAMESPACE) $(MYSQL_POD) -- sh -lc 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" -e "USE $(MYSQL_DB); SHOW TABLES;"'

mysql-backup: ## Backup DB to MYSQL_DUMP (default: /tmp/grpcdb.sql)
	@$(MAKE) --no-print-directory guard-context
	@set -euo pipefail; \
	out="$(MYSQL_DUMP)"; \
	mkdir -p "$$(dirname "$$out")"; \
	$(KUBECTL) get pod -n $(K8S_NAMESPACE) $(MYSQL_POD) >/dev/null; \
	echo "==> mysqldump $(MYSQL_DB) from $(MYSQL_POD) -> $$out"; \
	$(KUBECTL) exec -n $(K8S_NAMESPACE) $(MYSQL_POD) -- sh -lc 'mysqldump -uroot -p"$$MYSQL_ROOT_PASSWORD" $(MYSQL_DB)' > "$$out"; \
	ls -lh "$$out"

mysql-restore: ## Restore DB from MYSQL_DUMP into MYSQL_DB (DANGEROUS: overwrites data logically)
	@$(MAKE) --no-print-directory guard-context
	@set -euo pipefail; \
	in="$(MYSQL_DUMP)"; \
	test -f "$$in" || (echo "❌ dump not found: $$in" && exit 1); \
	$(KUBECTL) get pod -n $(K8S_NAMESPACE) $(MYSQL_POD) >/dev/null; \
	echo "==> restore $$in into $(MYSQL_DB) on $(MYSQL_POD)"; \
	$(KUBECTL) exec -n $(K8S_NAMESPACE) -i $(MYSQL_POD) -- sh -lc 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" $(MYSQL_DB)' < "$$in"; \
	echo "✅ restore done"

mysql-uninstall: ## Uninstall mysql release (DANGEROUS) [CONFIRM=1] (PVC may remain)
	@$(MAKE) --no-print-directory guard-context
	@if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
	$(HELM) uninstall $(MYSQL_RELEASE) -n $(K8S_NAMESPACE)

mysql-wipe: ## Uninstall mysql release + delete PVCs (VERY DANGEROUS) [CONFIRM=1]
	@$(MAKE) --no-print-directory guard-context
	@if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
	-$(HELM) uninstall $(MYSQL_RELEASE) -n $(K8S_NAMESPACE)
	@echo "==> deleting PVCs like data-$(MYSQL_RELEASE)-* in ns=$(K8S_NAMESPACE)"
	@p="$$( $(KUBECTL) get pvc -n $(K8S_NAMESPACE) --no-headers 2>/dev/null | awk '$$1 ~ /^data-$(MYSQL_RELEASE)-/ {print $$1}' )"; \
	if [ -z "$$p" ]; then echo "No PVCs found."; else echo "$$p" | xargs -r $(KUBECTL) delete pvc -n $(K8S_NAMESPACE); fi
