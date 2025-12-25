# =========================================
# Makefile (k8s/helm mainline)
# - Keep proto in mainline
# - Everything else (local dev, tools, docker run/compose, etc.) goes to Makefile.local
# =========================================
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------
# Basic tools (mainline needs these)
# ---------------------------------------------------------
KUBECTL ?= kubectl
HELM   ?= helm
KIND   ?= kind
DOCKER ?= docker

# ---------------------------------------------------------
# Kubernetes / kind
# ---------------------------------------------------------
K8S_NAMESPACE ?= default
KIND_CLUSTER  ?= grpc-echo

# =========================================================
# Images / Tags
#   - TAG は “kind load” と “helm --set global.imageTag” の唯一の基準
#   - デフォルトは git short sha -> fallback は日時
# =========================================================
GRPC_IMAGE_REPO ?= grpc-echo
GW_IMAGE_REPO   ?= grpc-http-gateway
TAG ?= $(shell (git rev-parse --short HEAD 2>/dev/null) || date +%Y%m%d%H%M%S)

# 互換: 古いコマンド/記述が残ってても動くように（徐々に消してOK）
IMAGE_TAG ?= $(TAG)

# ---------------------------------------------------------
# Helm / Chart (A: global.imageTag 一本化)
# ---------------------------------------------------------
HELM_RELEASE ?= grpc-echo
CHART_DIR    ?= ./helm/grpc-echo

ENV         ?= dev
VALUES_FILE ?= $(CHART_DIR)/values.$(ENV).yaml

# ---------------------------------------------------------
# Proto (mainline)
# ---------------------------------------------------------
PROTO_DIRS    := $(shell find api -name '*.proto' -exec dirname {} \; | sort -u)
GATEWAY_PROTOS := $(shell find api -name '*.proto' -print)

# ---------------------------------------------------------
# k-logs UX defaults (mainline)
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
##@ Main: Help
# =========================================================
.PHONY: help
help: ## Show help (main targets first; optional targets are listed after if Makefile.local exists)
	@awk ' \
	BEGIN {FS=":.*## "}; \
	/^##@/ {printf "\n%s\n", substr($$0,5); next} \
	/^[a-zA-Z0-9_.-]+:.*## / {printf "  %-24s %s\n", $$1, $$2} \
	' $(MAKEFILE_LIST)
	@echo ""
	@echo "Common vars:"
	@echo "  ENV=$(ENV)                    (dev|prod)"
	@echo "  VALUES_FILE=$(VALUES_FILE)"
	@echo "  TAG=$(TAG)"
	@echo "  K8S_NAMESPACE=$(K8S_NAMESPACE)"
	@echo "  KIND_CLUSTER=$(KIND_CLUSTER)"
	@echo ""

# =========================================================
##@ Main: Protobuf
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
##@ Main: Helm (tag-safe)
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

h-rollback: ## helm rollback
	$(HELM) rollback $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-uninstall: ## helm uninstall
	$(HELM) uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-values: ## helm get values -a
	$(HELM) get values $(HELM_RELEASE) -n $(K8S_NAMESPACE) -a

h-manifest: ## helm get manifest
	$(HELM) get manifest $(HELM_RELEASE) -n $(K8S_NAMESPACE)

# =========================================================
##@ Main: Kubernetes (observability / ops)
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
	$(KUBECTL) rollout status deploy/http-gateway -n $(K8S_NAMESPACE)

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

k-clean: ## Delete unhealthy pods (ImagePullBackOff/ErrImagePull/CrashLoopBackOff) in namespace
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

k-load: k-load-grpc k-load-gw ## Build both images and kind load both (tag=TAG)

k-rebuild-wait: k-load h-up-wait k-wait k-image-assert k-status ## Build->kind load->helm up(wait/atomic)->rollout->assert->status
	@echo "✅ Deployed with TAG=$(TAG) (ENV=$(ENV))"

# =========================================================
##@ Main: Smoke tests (Ingress port-forward assumed: make k-ingress-pf)
# =========================================================
.PHONY: smoke smoke-login smoke-todos

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

smoke: smoke-todos ## Smoke: login + list todos via ingress (requires k-ingress-pf running)
