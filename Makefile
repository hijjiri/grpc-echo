SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# =========================================================
# Core tools
# =========================================================
KUBECTL ?= kubectl
HELM   ?= helm
KIND   ?= kind
DOCKER ?= docker

# =========================================================
# Cluster / Namespace
# =========================================================
K8S_NAMESPACE ?= default
KIND_CLUSTER  ?= grpc-echo

# Expected kube context for kind (guarded)
K8S_CONTEXT_EXPECT ?= kind-$(KIND_CLUSTER)
ALLOW_OTHER_CONTEXT ?= 0

# =========================================================
# Images / Tag
#   TAG is the single source of truth for:
#     docker tag -> kind load -> helm --set global.imageTag
# =========================================================
GRPC_IMAGE_REPO ?= grpc-echo
GW_IMAGE_REPO   ?= grpc-http-gateway
TAG ?= $(shell (git rev-parse --short HEAD 2>/dev/null) || date +%Y%m%d%H%M%S)

# =========================================================
# Helm / Chart (App)
# =========================================================
HELM_RELEASE ?= grpc-echo
CHART_DIR    ?= ./helm/grpc-echo

ENV         ?= dev
VALUES_FILE ?= $(CHART_DIR)/values.$(ENV).yaml

# =========================================================
# Helm / Chart (MySQL)
# =========================================================
MYSQL_RELEASE    ?= mysql
MYSQL_CHART_DIR  ?= ./helm/mysql
MYSQL_DB         ?= grpcdb
MYSQL_POD        ?= mysql-0
MYSQL_DUMP       ?= /tmp/grpcdb.sql

# =========================================================
# Protobuf
# =========================================================
PROTOC ?= protoc
PROTO_DIRS      := $(shell find api -name '*.proto' -exec dirname {} \; | sort -u)
GATEWAY_PROTOS  := $(shell find api -name '*.proto' -print)

# =========================================================
# Optional local dev tools / addresses
# =========================================================
GO       ?= go
GO_RUN   ?= $(GO) run
GO_BUILD ?= $(GO) build

GRPCURL ?= grpcurl
EVANS   ?= evans

GRPC_ADDR         ?= localhost:50051
HTTP_GATEWAY_ADDR ?= localhost:8081
METRICS_ADDR      ?= localhost:9464

GRPC_PORT         := $(word 2,$(subst :, ,$(GRPC_ADDR)))
HTTP_GATEWAY_PORT := $(word 2,$(subst :, ,$(HTTP_GATEWAY_ADDR)))
METRICS_PORT      := $(word 2,$(subst :, ,$(METRICS_ADDR)))

SERVICE ?=
JWT_SECRET ?= my-dev-secret-key

# docker compose: prefer "docker compose", fallback to "docker-compose"
DOCKER_COMPOSE ?= $(shell \
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then \
    echo "docker compose"; \
  elif command -v docker-compose >/dev/null 2>&1; then \
    echo "docker-compose"; \
  else \
    echo "docker compose"; \
  fi)

# =========================================================
# B-Extension switches (one-command bootstrap)
# =========================================================
AUTO        ?= 0         # AUTO=1 -> run port-forward + smoke automatically
AUTO_KIND   ?= 1         # create kind cluster if missing
AUTO_INGRESS?= 1         # install ingress-nginx if missing
AUTO_HOSTS  ?= 0         # edit /etc/hosts automatically (requires CONFIRM=1)
AUTO_OBS    ?= 0         # apply observability via kustomize + wait
CONFIRM     ?= 0

# Ingress-nginx (Helm)
INGRESS_NS      ?= ingress-nginx
INGRESS_RELEASE ?= ingress-nginx
INGRESS_CHART   ?= ingress-nginx/ingress-nginx
INGRESS_VALUES_KIND ?= ./k8s/ingress-nginx/values.kind.yaml

# Ingress host & port-forward
INGRESS_HOST    ?= grpc-echo.local
INGRESS_PF_PORT ?= 8080

# Observability (Kustomize)
OBS_DIR ?= ./k8s/observability

# =========================================================
# Local overrides file (NO TARGETS POLICY)
# =========================================================
-include Makefile.local

# =========================================================
# Help
# =========================================================
.PHONY: help
help: ## Show help
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
	@echo "B-ext:"
	@echo "  make gp AUTO=1 AUTO_OBS=1 AUTO_HOSTS=1 CONFIRM=1"
	@echo ""

# =========================================================
##@ Safety / Preflight
# =========================================================
.PHONY: guard-context preflight check-values

guard-context: ## Guard: verify kubectl context (ALLOW_OTHER_CONTEXT=1 to bypass)
	@set -euo pipefail; \
	ctx="$$( $(KUBECTL) config current-context 2>/dev/null || true )"; \
	exp="$(K8S_CONTEXT_EXPECT)"; \
	if [ "$(ALLOW_OTHER_CONTEXT)" = "1" ] || [ -z "$$exp" ]; then exit 0; fi; \
	if [ "$$ctx" != "$$exp" ]; then \
	  echo "❌ Refusing: kubectl context is '$$ctx' but expected '$$exp'"; \
	  echo "   If you know what you're doing, run with ALLOW_OTHER_CONTEXT=1"; \
	  exit 1; \
	fi

preflight: ## Preflight checks (tools)
	@set -euo pipefail; \
	for c in $(KUBECTL) $(HELM) $(KIND) $(DOCKER); do \
	  command -v $$c >/dev/null 2>&1 || (echo "missing command: $$c" && exit 1); \
	done; \
	echo "tools OK"

check-values: ## Check ENV/VALUES_FILE exists
	@set -euo pipefail; \
	test -f "$(VALUES_FILE)" || (echo "values file not found: $(VALUES_FILE) (ENV=$(ENV))" && exit 1)

# =========================================================
##@ Golden Path (A + B extension)
# =========================================================
.PHONY: gp gp-auto gp-bootstrap kind-ensure ingress-ensure hosts-ensure obs-ensure gp-maybe-smoke

gp: preflight kind-ensure guard-context ingress-ensure hosts-ensure obs-ensure check-values mysql-up-wait k-rebuild-wait gp-maybe-smoke ## One-command deploy (AUTO=1 for pf+smoke)

gp-auto: ## Fully automatic: gp + port-forward + smoke (AUTO=1 AUTO_HOSTS=1 needs CONFIRM=1)
	@$(MAKE) --no-print-directory gp AUTO=1 AUTO_HOSTS=1

kind-ensure: ## Ensure kind cluster exists (AUTO_KIND=1)
	@set -euo pipefail; \
	if [ "$(AUTO_KIND)" != "1" ]; then \
	  echo "==> kind ensure skipped (AUTO_KIND=$(AUTO_KIND))"; \
	  exit 0; \
	fi; \
	if ! command -v $(KIND) >/dev/null 2>&1; then echo "❌ kind not found"; exit 1; fi; \
	if $(KIND) get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
	  echo "✅ kind cluster exists: $(KIND_CLUSTER)"; \
	else \
	  echo "==> creating kind cluster: $(KIND_CLUSTER)"; \
	  $(KIND) create cluster --name "$(KIND_CLUSTER)"; \
	fi

ingress-ensure: ## Ensure ingress-nginx installed (AUTO_INGRESS=1) [kind-optimized]
	@set -euo pipefail; \
	if [ "$(AUTO_INGRESS)" != "1" ]; then \
	  echo "==> ingress ensure skipped (AUTO_INGRESS=$(AUTO_INGRESS))"; \
	  exit 0; \
	fi; \
	$(MAKE) --no-print-directory guard-context; \
	if $(KUBECTL) get ns "$(INGRESS_NS)" >/dev/null 2>&1; then \
	  echo "✅ namespace exists: $(INGRESS_NS)"; \
	else \
	  echo "==> creating namespace: $(INGRESS_NS)"; \
	  $(KUBECTL) create namespace "$(INGRESS_NS)"; \
	fi; \
	if $(KUBECTL) get deploy -n "$(INGRESS_NS)" ingress-nginx-controller >/dev/null 2>&1; then \
	  echo "✅ ingress-nginx already installed"; \
	else \
	  echo "==> installing ingress-nginx via helm (kind optimized)"; \
	  $(HELM) repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true; \
	  $(HELM) repo update >/dev/null 2>&1 || true; \
	  if [ -f "$(INGRESS_VALUES_KIND)" ]; then \
	    echo "==> using values: $(INGRESS_VALUES_KIND)"; \
	    $(HELM) upgrade --install "$(INGRESS_RELEASE)" "$(INGRESS_CHART)" \
	      -n "$(INGRESS_NS)" --create-namespace \
	      -f "$(INGRESS_VALUES_KIND)" \
	      --wait --timeout 10m; \
	  else \
	    echo "⚠️ values file not found: $(INGRESS_VALUES_KIND) (using inline defaults)"; \
	    $(HELM) upgrade --install "$(INGRESS_RELEASE)" "$(INGRESS_CHART)" \
	      -n "$(INGRESS_NS)" --create-namespace \
	      --set controller.publishService.enabled=true \
	      --wait --timeout 10m; \
	  fi; \
	fi; \
	echo "==> waiting ingress-nginx rollout"; \
	$(KUBECTL) rollout status -n "$(INGRESS_NS)" deploy/ingress-nginx-controller --timeout=10m

hosts-ensure: ## Optionally ensure /etc/hosts has INGRESS_HOST -> 127.0.0.1 (AUTO_HOSTS=1 requires CONFIRM=1)
	@set -euo pipefail; \
	if [ "$(AUTO_HOSTS)" != "1" ]; then \
	  echo "==> hosts update skipped (AUTO_HOSTS=$(AUTO_HOSTS))"; \
	  echo "    If you want it: make hosts-up CONFIRM=1"; \
	  exit 0; \
	fi; \
	if [ "$(CONFIRM)" != "1" ]; then \
	  echo "❌ Refusing to edit /etc/hosts without CONFIRM=1"; \
	  echo "   Run: make gp AUTO_HOSTS=1 CONFIRM=1"; \
	  exit 1; \
	fi; \
	if grep -qE "^[0-9\.]+\s+$(INGRESS_HOST)(\s|$$)" /etc/hosts; then \
	  echo "✅ /etc/hosts already has $(INGRESS_HOST)"; \
	else \
	  echo "==> adding 127.0.0.1 $(INGRESS_HOST) to /etc/hosts"; \
	  echo "127.0.0.1 $(INGRESS_HOST)" | sudo tee -a /etc/hosts >/dev/null; \
	fi

obs-ensure: ## Optionally apply observability via kustomize and wait (AUTO_OBS=1)
	@set -euo pipefail; \
	if [ "$(AUTO_OBS)" != "1" ]; then \
	  echo "==> observability ensure skipped (AUTO_OBS=$(AUTO_OBS))"; \
	  exit 0; \
	fi; \
	$(MAKE) --no-print-directory obs-up; \
	$(MAKE) --no-print-directory obs-wait; \
	$(MAKE) --no-print-directory obs-status

gp-maybe-smoke: ## If AUTO=1 then run port-forward and smoke automatically
	@set -euo pipefail; \
	if [ "$(AUTO)" != "1" ]; then \
	  echo ""; \
	  echo "✅ gp completed (apps deployed)."; \
	  echo "Next:"; \
	  echo "  1) make k-ingress-pf   (keep this terminal open)"; \
	  echo "  2) make smoke          (in another terminal)"; \
	  echo ""; \
	  echo "To fully automate: make gp AUTO=1 (and AUTO_HOSTS=1 CONFIRM=1 if needed)"; \
	  exit 0; \
	fi; \
	$(MAKE) --no-print-directory gp-smoke-run

# =========================================================
##@ Observability (Kustomize apply + wait)
# =========================================================
.PHONY: obs-up obs-wait obs-status obs-down

obs-up: ## Apply observability stack via kustomize (uses K8S_NAMESPACE)
	@$(MAKE) --no-print-directory guard-context
	@set -euo pipefail; \
	test -f "$(OBS_DIR)/kustomization.yaml" || (echo "❌ missing: $(OBS_DIR)/kustomization.yaml" && exit 1); \
	echo "==> kubectl apply -k $(OBS_DIR) -n $(K8S_NAMESPACE)"; \
	$(KUBECTL) apply -n $(K8S_NAMESPACE) -k $(OBS_DIR)

obs-wait: ## Wait until observability deployments are ready
	@$(MAKE) --no-print-directory guard-context
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; \
	echo "==> waiting for observability deployments in ns=$$ns"; \
	for d in otel-collector tempo prometheus grafana; do \
	  if $(KUBECTL) get deploy $$d -n $$ns >/dev/null 2>&1; then \
	    echo " -> rollout status deploy/$$d"; \
	    $(KUBECTL) rollout status deploy/$$d -n $$ns --timeout=10m; \
	  else \
	    echo " -> deploy/$$d not found (skip)"; \
	  fi; \
	done; \
	echo "✅ observability ready"

obs-status: ## Show observability pods/svc
	@$(MAKE) --no-print-directory guard-context
	@echo "== Pods =="; $(KUBECTL) get pods -n $(K8S_NAMESPACE) | egrep 'NAME|otel-collector|tempo|prometheus|grafana' || true
	@echo ""
	@echo "== Svc =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE) | egrep 'NAME|otel-collector|tempo|prometheus|grafana' || true

obs-down: ## Delete observability stack via kustomize (DANGEROUS) [CONFIRM=1]
	@$(MAKE) --no-print-directory guard-context
	@if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
	@set -euo pipefail; \
	echo "==> kubectl delete -k $(OBS_DIR) -n $(K8S_NAMESPACE)"; \
	$(KUBECTL) delete -n $(K8S_NAMESPACE) -k $(OBS_DIR) || true

# =========================================================
##@ Proto
# =========================================================
.PHONY: proto proto-preflight

proto-preflight: ## Check protoc + plugins exist
	@set -euo pipefail; \
	command -v $(PROTOC) >/dev/null 2>&1 || (echo "❌ missing command: $(PROTOC)" && exit 1); \
	command -v protoc-gen-go >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-go" && exit 1); \
	command -v protoc-gen-go-grpc >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-go-grpc" && exit 1); \
	command -v protoc-gen-grpc-gateway >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-grpc-gateway" && exit 1); \
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
##@ Helm (App) - tag-safe
# =========================================================
.PHONY: h-template h-lint h-status h-up h-up-wait h-rollback h-uninstall h-values h-manifest

h-template: check-values ## helm template (ENV=dev|prod, TAG=...)
	@$(MAKE) --no-print-directory guard-context
	$(HELM) template $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) -f $(VALUES_FILE) \
	  --set global.imageTag=$(TAG)

h-lint: ## helm lint
	$(HELM) lint $(CHART_DIR)

h-status: ## helm status
	@$(MAKE) --no-print-directory guard-context
	$(HELM) status $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-up: check-values ## helm upgrade --install (no wait)
	@$(MAKE) --no-print-directory guard-context
	$(HELM) upgrade --install $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) \
	  -f $(VALUES_FILE) \
	  --set global.imageTag=$(TAG)

h-up-wait: check-values ## helm upgrade --install --wait --timeout 5m --atomic
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
##@ Kubernetes (ops)
# =========================================================
.PHONY: context diag k-status k-events k-describe k-logs k-wait k-image-check k-image-assert k-ingress-pf k-clean

context: ## Show current kubectl context + ns + nodes
	@$(MAKE) --no-print-directory guard-context
	@echo "context: $$($(KUBECTL) config current-context)"; \
	echo "ns     : $(K8S_NAMESPACE)"; \
	echo ""; \
	$(KUBECTL) get nodes -o wide

diag: ## Quick diagnostics bundle (context/status/events/helm/mysql/obs)
	@$(MAKE) --no-print-directory context
	@echo ""
	@$(MAKE) --no-print-directory k-status
	@echo ""
	@$(MAKE) --no-print-directory k-events
	@echo ""
	@$(MAKE) --no-print-directory h-status || true
	@$(MAKE) --no-print-directory mysql-status || true
	@$(MAKE) --no-print-directory obs-status || true

k-status: ## Show pods/services/ingress
	@$(MAKE) --no-print-directory guard-context
	@echo "== Pods =="; $(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide
	@echo ""
	@echo "== Services =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE)
	@echo ""
	@echo "== Ingress =="; $(KUBECTL) get ingress -n $(K8S_NAMESPACE) || true

k-events: ## Show recent events (sorted)
	@$(MAKE) --no-print-directory guard-context
	@$(KUBECTL) get events -n $(K8S_NAMESPACE) --sort-by=.lastTimestamp | tail -n 60 || true

k-describe: ## Describe key pods (grpc-echo/http-gateway/mysql-0)
	@$(MAKE) --no-print-directory guard-context
	@set -euo pipefail; \
	ns="$(K8S_NAMESPACE)"; \
	for p in $$( $(KUBECTL) get pod -n $$ns -o name | egrep 'grpc-echo-|http-gateway-|mysql-0' || true ); do \
	  echo "===== describe $$p ====="; \
	  $(KUBECTL) describe -n $$ns $$p | sed -n '/^Name:/,/^Events:/p'; \
	  echo ""; \
	done

# k-logs defaults
APP       ?= grpc-echo
POD       ?=
CONTAINER ?=
TAIL      ?= 200
FOLLOW    ?= 1
SINCE     ?=
PREVIOUS  ?= 0

k-logs: ## Tail logs. Use APP=..., POD=..., CONTAINER=..., TAIL=..., FOLLOW=1, SINCE=..., PREVIOUS=1
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
	@echo "grpc-echo image:"; $(KUBECTL) get deploy grpc-echo -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
	@echo "http-gateway image:"; $(KUBECTL) get deploy http-gateway -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

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

k-ingress-pf: ## Port-forward ingress-nginx controller to localhost:8080 (manual mode)
	@$(MAKE) --no-print-directory guard-context
	@$(KUBECTL) get svc -n $(INGRESS_NS) ingress-nginx-controller >/dev/null 2>&1 || \
	  (echo "❌ ingress-nginx-controller not found. Try: make ingress-ensure" && exit 1)
	$(KUBECTL) port-forward -n $(INGRESS_NS) svc/ingress-nginx-controller $(INGRESS_PF_PORT):80

k-clean: ## Delete unhealthy pods (ImagePullBackOff/ErrImagePull/CrashLoopBackOff)
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
##@ kind rebuild (tag-safe end-to-end)
# =========================================================
.PHONY: k-load-grpc k-load-gw k-load k-rebuild-wait

k-load-grpc: ## docker build grpc-echo:TAG -> kind load
	$(DOCKER) build -t $(GRPC_IMAGE_REPO):$(TAG) .
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GRPC_IMAGE_REPO):$(TAG)

k-load-gw: ## docker build grpc-http-gateway:TAG -> kind load
	$(DOCKER) build -f Dockerfile.http_gateway -t $(GW_IMAGE_REPO):$(TAG) .
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GW_IMAGE_REPO):$(TAG)

k-load: k-load-grpc k-load-gw ## Build both images and kind load both

k-rebuild-wait: k-load h-up-wait k-wait k-image-assert ## Build->kind load->helm up(wait/atomic)->rollout->assert
	@echo "✅ Deployed with TAG=$(TAG) (ENV=$(ENV))"

# =========================================================
##@ Smoke tests (Ingress port-forward assumed)
# =========================================================
.PHONY: smoke smoke-login smoke-todos

smoke-login: ## Smoke: login via ingress and print token
	@echo "==> POST http://$(INGRESS_HOST):$(INGRESS_PF_PORT)/auth/login"
	@resp=$$(curl -sS http://$(INGRESS_HOST):$(INGRESS_PF_PORT)/auth/login \
	  -H "Content-Type: application/json" \
	  -d '{"username":"user-123","password":"password"}' || true); \
	if [ -z "$$resp" ]; then \
	  echo "❌ request failed. Is port-forward running?"; exit 1; \
	fi; \
	echo "$$resp"; \
	if command -v jq >/dev/null 2>&1; then \
	  echo "$$resp" | jq -r '.accessToken'; \
	else \
	  echo "$$resp" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'; \
	fi

smoke-todos: ## Smoke: list todos via ingress (auto token)
	@echo "==> GET http://$(INGRESS_HOST):$(INGRESS_PF_PORT)/v1/todos"
	@token="$${TOKEN:-}"; \
	if [ -z "$$token" ]; then \
	  resp=$$(curl -sS http://$(INGRESS_HOST):$(INGRESS_PF_PORT)/auth/login \
	    -H "Content-Type: application/json" \
	    -d '{"username":"user-123","password":"password"}' || true); \
	  if [ -z "$$resp" ]; then echo "❌ request failed. Is port-forward running?"; exit 1; fi; \
	  if command -v jq >/dev/null 2>&1; then \
	    token=$$(echo "$$resp" | jq -r '.accessToken'); \
	  else \
	    token=$$(echo "$$resp" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'); \
	  fi; \
	fi; \
	curl -sS http://$(INGRESS_HOST):$(INGRESS_PF_PORT)/v1/todos \
	  -H "Authorization: Bearer $$token" | (command -v jq >/dev/null 2>&1 && jq . || cat); \
	echo ""

smoke: smoke-todos ## Smoke: login + list todos via ingress

# =========================================================
##@ MySQL (Helm)
# =========================================================
.PHONY: mysql-up mysql-up-wait mysql-wait mysql-status mysql-logs mysql-shell mysql-init-check mysql-backup mysql-restore mysql-uninstall mysql-wipe

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

mysql-restore: ## Restore DB from MYSQL_DUMP into MYSQL_DB
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

# =========================================================
##@ AUTO=1 helpers (background port-forward + smoke)
# =========================================================
PF_PID_FILE ?= .tmp/ingress-pf.pid

.PHONY: gp-smoke-run gp-ingress-pf-bg gp-pf-stop

gp-smoke-run:
	@set -euo pipefail; \
	echo "==> starting ingress port-forward in background (localhost:$(INGRESS_PF_PORT))"; \
	$(MAKE) --no-print-directory gp-ingress-pf-bg; \
	echo "==> waiting for ingress to be reachable..."; \
	for i in $$(seq 1 60); do \
	  if curl -sS "http://$(INGRESS_HOST):$(INGRESS_PF_PORT)/" >/dev/null 2>&1; then \
	    echo "✅ ingress reachable"; break; \
	  fi; \
	  sleep 0.25; \
	  if [ $$i -eq 60 ]; then echo "❌ ingress not reachable (port-forward failed?)"; exit 1; fi; \
	done; \
	echo "==> running smoke"; \
	$(MAKE) --no-print-directory smoke; \
	echo ""; \
	echo "✅ AUTO run finished. Port-forward still running. Stop it with: make gp-pf-stop"

gp-ingress-pf-bg:
	@set -euo pipefail; \
	mkdir -p .tmp; \
	if [ -f "$(PF_PID_FILE)" ]; then \
	  pid="$$(cat $(PF_PID_FILE) 2>/dev/null || true)"; \
	  if [ -n "$$pid" ] && kill -0 "$$pid" >/dev/null 2>&1; then \
	    echo "✅ ingress port-forward already running (pid=$$pid)"; \
	    exit 0; \
	  else \
	    rm -f "$(PF_PID_FILE)"; \
	  fi; \
	fi; \
	( $(KUBECTL) port-forward -n $(INGRESS_NS) svc/ingress-nginx-controller $(INGRESS_PF_PORT):80 >/tmp/ingress-pf.log 2>&1 & echo $$! > "$(PF_PID_FILE)" ); \
	echo "started pid=$$(cat $(PF_PID_FILE)) (log=/tmp/ingress-pf.log)"; \
	sleep 0.3

gp-pf-stop: ## Stop ingress port-forward started by AUTO=1
	@set -euo pipefail; \
	if [ -f "$(PF_PID_FILE)" ]; then \
	  pid="$$(cat $(PF_PID_FILE) 2>/dev/null || true)"; \
	  if [ -n "$$pid" ] && kill -0 "$$pid" >/dev/null 2>&1; then \
	    echo "==> stopping pid=$$pid"; kill "$$pid" || true; \
	  fi; \
	  rm -f "$(PF_PID_FILE)"; \
	else \
	  echo "no pid file: $(PF_PID_FILE)"; \
	fi

# =========================================================
##@ Optional: Local dev (Go / Docker / Compose / Tools)
# =========================================================
.PHONY: preflight-local run-server run-gateway build-server docker-run-grpc docker-run-gw docker-stop-grpc docker-stop-gw
.PHONY: compose-up compose-db compose-down compose-logs compose-ps fmt vet lint test build tree
.PHONY: health evans jwt jwt-print k-grpc k-gw k-metrics k-graf kind-down hosts-up hosts-down

preflight-local: ## (Optional) Preflight checks for local-only tools
	@set -euo pipefail; \
	for c in $(GO) $(GRPCURL); do \
	  command -v $$c >/dev/null 2>&1 || (echo "❌ missing command: $$c" && exit 1); \
	done; \
	echo "✅ local tools OK"

run-server: preflight-local ## (Optional) Run gRPC server locally
	$(GO_RUN) ./cmd/server

build-server: ## (Optional) Build gRPC server binary (./server)
	$(GO_BUILD) -o server ./cmd/server

run-gateway: preflight-local ## (Optional) Run HTTP gateway locally
	$(GO_RUN) ./cmd/http_gateway

docker-run-grpc: ## (Optional) Run grpc-echo container locally
	$(DOCKER) run --rm -p $(GRPC_PORT):50051 --name grpc-echo $(GRPC_IMAGE_REPO):$(TAG)

docker-run-gw: ## (Optional) Run http-gateway container locally
	$(DOCKER) run --rm -p $(HTTP_GATEWAY_PORT):8081 \
	  -e GRPC_SERVER_ADDR=$(GRPC_ADDR) -e HTTP_LISTEN_ADDR=:8081 \
	  --name grpc-http-gateway $(GW_IMAGE_REPO):$(TAG)

docker-stop-grpc: ## (Optional) Stop grpc-echo container
	-$(DOCKER) stop grpc-echo >/dev/null 2>&1 || true

docker-stop-gw: ## (Optional) Stop http-gateway container
	-$(DOCKER) stop grpc-http-gateway >/dev/null 2>&1 || true

compose-up: ## (Optional) docker compose up --build
	$(DOCKER_COMPOSE) up --build

compose-db: ## (Optional) docker compose up -d db
	$(DOCKER_COMPOSE) up -d db

compose-down: ## (Optional) docker compose down
	$(DOCKER_COMPOSE) down

compose-logs: ## (Optional) docker compose logs -f
	$(DOCKER_COMPOSE) logs -f

compose-ps: ## (Optional) docker compose ps
	$(DOCKER_COMPOSE) ps

fmt: ## (Optional) gofmt all *.go
	@echo "==> gofmt all *.go"
	@gofmt -w $$(find . -name '*.go' -not -path "./vendor/*")

vet: ## (Optional) go vet ./...
	$(GO) vet ./...

lint: fmt vet ## (Optional) fmt + vet

test: ## (Optional) go test ./...
	$(GO) test ./...

build: ## (Optional) go build ./...
	$(GO) build ./...

tree: ## (Optional) tree -L 4
	tree -L 4

health: preflight-local ## (Optional) gRPC health check (SERVICE=... optional)
	@if [ -z "$(SERVICE)" ]; then \
		$(GRPCURL) -plaintext -d '{}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	else \
		$(GRPCURL) -plaintext -d '{"service":"$(SERVICE)"}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	fi

evans: ## (Optional) evans repl to gRPC
	$(EVANS) --host $(word 1,$(subst :, ,$(GRPC_ADDR))) --port $(GRPC_PORT) -r repl

jwt-print: ## (Optional) Print token only (cmd/jwt_gen)
	cd cmd/jwt_gen && AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .

jwt: ## (Optional) Print 'export TOKEN=...' for eval
	@set -euo pipefail; \
	token=$$(cd cmd/jwt_gen && AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .); \
	echo "export TOKEN=$$token"

k-grpc: ## (Optional) port-forward grpc-echo service (grpc)
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo $(GRPC_PORT):50051

k-gw: ## (Optional) port-forward http-gateway service
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/http-gateway $(HTTP_GATEWAY_PORT):8081

k-metrics: ## (Optional) port-forward metrics
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo $(METRICS_PORT):9464

k-graf: ## (Optional) port-forward grafana (localhost:3000)
	@$(MAKE) --no-print-directory guard-context
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grafana 3000:3000

kind-down: ## (Optional) Delete kind cluster (DANGEROUS) [CONFIRM=1]
	@if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
	$(KIND) delete cluster --name "$(KIND_CLUSTER)"

hosts-up: ## (Optional) Add INGRESS_HOST to /etc/hosts (DANGEROUS) [CONFIRM=1]
	@if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
	@grep -qE "^[0-9\.]+\s+$(INGRESS_HOST)(\s|$$)" /etc/hosts || echo "127.0.0.1 $(INGRESS_HOST)" | sudo tee -a /etc/hosts >/dev/null
	@echo "✅ /etc/hosts updated ($(INGRESS_HOST))"

hosts-down: ## (Optional) Remove INGRESS_HOST from /etc/hosts (DANGEROUS) [CONFIRM=1]
	@if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
	@sudo sed -i.bak "/$(INGRESS_HOST)/d" /etc/hosts
	@echo "✅ /etc/hosts cleaned ($(INGRESS_HOST))"
