SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
.RECIPEPREFIX := >

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
# Images / Tag (single source of truth)
# =========================================================
GRPC_IMAGE_REPO ?= grpc-echo
GW_IMAGE_REPO   ?= grpc-http-gateway
TAG ?= $(shell (git rev-parse --short HEAD 2>/dev/null) || date +%Y%m%d%H%M%S)

# =========================================================
# Helm / Chart (App)
# =========================================================
HELM_RELEASE ?= grpc-echo
CHART_DIR    ?= ./helm/grpc-echo

ENV ?= dev
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
PROTO_DIRS     := $(shell find api -name '*.proto' -exec dirname {} \; | sort -u)
GATEWAY_PROTOS := $(shell find api -name '*.proto' -print)

# =========================================================
# Optional local dev tools / addresses
# =========================================================
GO ?= go
GO_RUN ?= $(GO) run
GO_BUILD ?= $(GO) build

GRPCURL ?= grpcurl
EVANS   ?= evans

GRPC_ADDR ?= localhost:50051
HTTP_GATEWAY_ADDR ?= localhost:8081
METRICS_ADDR ?= localhost:9464

GRPC_PORT := $(word 2,$(subst :, ,$(GRPC_ADDR)))
HTTP_GATEWAY_PORT := $(word 2,$(subst :, ,$(HTTP_GATEWAY_ADDR)))
METRICS_PORT := $(word 2,$(subst :, ,$(METRICS_ADDR)))

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
# Golden Path switches
# =========================================================
# AUTO=1 -> direct smoke automatically (NO port-forward)
AUTO ?= 0
AUTO_KIND ?= 1
AUTO_INGRESS ?= 1
# edit /etc/hosts (requires CONFIRM=1)
AUTO_HOSTS ?= 0
# apply observability via kustomize + wait
AUTO_OBS ?= 0
CONFIRM ?= 0

# =========================================================
# Ingress (kind optimized: NodePort + extraPortMappings)
# =========================================================
INGRESS_NS ?= ingress-nginx
INGRESS_RELEASE ?= ingress-nginx
INGRESS_CHART ?= ingress-nginx/ingress-nginx
INGRESS_VALUES_KIND ?= ./k8s/ingress-nginx/values.kind.yaml

INGRESS_HOST ?= grpc-echo.local
INGRESS_HTTP_PORT ?= 8080
INGRESS_HTTPS_PORT ?= 8443

INGRESS_NODEPORT_HTTP ?= 30080
INGRESS_NODEPORT_HTTPS ?= 30443

# kind config generation (auto)
KIND_CONFIG_DIR ?= .tmp
KIND_CONFIG_FILE ?= $(KIND_CONFIG_DIR)/kind-config.yaml
# Safer default; override in Makefile.local if you need 0.0.0.0
KIND_LISTEN_ADDR ?= 127.0.0.1

# =========================================================
# Observability (Kustomize apply + wait)
# =========================================================
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
> @awk ' \
	BEGIN {FS=":.*## "}; \
	/^##@/ {printf "\n%s\n", substr($$0,5); next} \
	/^[a-zA-Z0-9_.-]+:.*## / {printf "  %-28s %s\n", $$1, $$2} \
	' $(MAKEFILE_LIST)
> @echo ""
> @echo "Examples:"
> @echo "  make gp AUTO=1                                # kind+ingress+app+mysql + direct smoke"
> @echo "  make gp AUTO=1 AUTO_HOSTS=1 CONFIRM=1          # + /etc/hosts update"
> @echo "  make proto                                    # generate protobuf"
> @echo "  make diag                                     # troubleshooting snapshot"
> @echo ""

# =========================================================
##@ Safety / Preflight
# =========================================================
.PHONY: guard-context preflight check-values ports-check

guard-context: ## Guard: verify kubectl context (ALLOW_OTHER_CONTEXT=1 to bypass)
> @set -euo pipefail; \
	ctx="$$( $(KUBECTL) config current-context 2>/dev/null || true )"; \
	exp="$(K8S_CONTEXT_EXPECT)"; \
	if [ "$(ALLOW_OTHER_CONTEXT)" = "1" ] || [ -z "$$exp" ]; then exit 0; fi; \
	if [ "$$ctx" != "$$exp" ]; then \
	  echo "❌ Refusing: kubectl context is '$$ctx' but expected '$$exp'"; \
	  echo "   If you know what you're doing, run with ALLOW_OTHER_CONTEXT=1"; \
	  exit 1; \
	fi

preflight: ## Preflight checks (tools)
> @set -euo pipefail; \
	for c in $(KUBECTL) $(HELM) $(KIND) $(DOCKER); do \
	  command -v $$c >/dev/null 2>&1 || (echo "❌ missing command: $$c" && exit 1); \
	done; \
	if ! $(DOCKER) buildx version >/dev/null 2>&1; then \
	  echo "⚠️ docker buildx not found (legacy builder will be used; Docker may warn)"; \
	fi; \
	echo "✅ tools OK"

check-values: ## Check ENV/VALUES_FILE exists
> @set -euo pipefail; \
	test -f "$(VALUES_FILE)" || (echo "❌ values file not found: $(VALUES_FILE) (ENV=$(ENV))" && exit 1)

ports-check: ## Check host ports availability (skip if kind already owns them)
> @set -euo pipefail; \
	if $(KIND) get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
	  line="$$( $(DOCKER) ps --format '{{.Names}} {{.Ports}}' | awk '$$1=="$(KIND_CLUSTER)-control-plane"{print $$0}' )"; \
	  if [ -n "$$line" ] && echo "$$line" | grep -qE "[:.]$(INGRESS_HTTP_PORT)->$(INGRESS_NODEPORT_HTTP)/tcp" && echo "$$line" | grep -qE "[:.]$(INGRESS_HTTPS_PORT)->$(INGRESS_NODEPORT_HTTPS)/tcp"; then \
	    echo "✅ host ports already published by kind ($(KIND_CLUSTER)): $(INGRESS_HTTP_PORT), $(INGRESS_HTTPS_PORT)"; \
	    exit 0; \
	  fi; \
	  echo "❌ kind cluster exists but port mapping doesn't match expected ports."; \
	  echo "   expected: host $(INGRESS_HTTP_PORT)->$(INGRESS_NODEPORT_HTTP), $(INGRESS_HTTPS_PORT)->$(INGRESS_NODEPORT_HTTPS)"; \
	  echo "   hint: update Makefile.local and recreate cluster: make kind-down CONFIRM=1 && make kind-ensure"; \
	  exit 1; \
	fi; \
	if command -v ss >/dev/null 2>&1; then \
	  for p in $(INGRESS_HTTP_PORT) $(INGRESS_HTTPS_PORT); do \
	    if ss -lnt | awk '{print $$4}' | grep -qE "[:.]$$p$$"; then \
	      echo "❌ port $$p already in use (change INGRESS_HTTP_PORT/INGRESS_HTTPS_PORT)"; exit 1; \
	    fi; \
	  done; \
	  echo "✅ host ports free: $(INGRESS_HTTP_PORT), $(INGRESS_HTTPS_PORT)"; \
	else \
	  echo "⚠️ ss not found; skipping port check"; \
	fi

# =========================================================
##@ Golden Path
# =========================================================
.PHONY: gp gp-auto
gp: preflight ports-check kind-ensure guard-context ingress-ensure hosts-ensure obs-ensure check-values mysql-up-wait k-rebuild-wait gp-maybe-smoke ## One-command deploy (AUTO=1 -> direct smoke)
gp-auto: ## Fully automatic example
> @$(MAKE) --no-print-directory gp AUTO=1 AUTO_HOSTS=1

# =========================================================
##@ kind (auto generated config + extraPortMappings)
# =========================================================
.PHONY: kind-config-gen kind-ensure kind-down

kind-config-gen: ## Generate kind config (host ports -> node NodePorts)
> @set -euo pipefail; \
	mkdir -p "$(KIND_CONFIG_DIR)"; \
	{ \
	  printf "%s\n" \
	    "kind: Cluster" \
	    "apiVersion: kind.x-k8s.io/v1alpha4" \
	    "name: $(KIND_CLUSTER)" \
	    "nodes:" \
	    "  - role: control-plane" \
	    "    extraPortMappings:" \
	    "      - containerPort: $(INGRESS_NODEPORT_HTTP)" \
	    "        hostPort: $(INGRESS_HTTP_PORT)" \
	    "        listenAddress: \"$(KIND_LISTEN_ADDR)\"" \
	    "        protocol: TCP" \
	    "      - containerPort: $(INGRESS_NODEPORT_HTTPS)" \
	    "        hostPort: $(INGRESS_HTTPS_PORT)" \
	    "        listenAddress: \"$(KIND_LISTEN_ADDR)\"" \
	    "        protocol: TCP" \
	    "    kubeadmConfigPatches:" \
	    "      - |" \
	    "        kind: InitConfiguration" \
	    "        nodeRegistration:" \
	    "          kubeletExtraArgs:" \
	    "            node-labels: \"ingress-ready=true\""; \
	} > "$(KIND_CONFIG_FILE)"; \
	echo "✅ generated: $(KIND_CONFIG_FILE)"; \
	echo "   host :$(INGRESS_HTTP_PORT)/:$(INGRESS_HTTPS_PORT) -> node :$(INGRESS_NODEPORT_HTTP)/:$(INGRESS_NODEPORT_HTTPS)"

kind-ensure: ## Ensure kind cluster exists (AUTO_KIND=1) using generated config
> @set -euo pipefail; \
	if [ "$(AUTO_KIND)" != "1" ]; then \
	  echo "==> kind ensure skipped (AUTO_KIND=$(AUTO_KIND))"; \
	  exit 0; \
	fi; \
	command -v $(KIND) >/dev/null 2>&1 || (echo "❌ kind not found" && exit 1); \
	if $(KIND) get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
	  echo "✅ kind cluster exists: $(KIND_CLUSTER)"; \
	else \
	  $(MAKE) --no-print-directory kind-config-gen; \
	  echo "==> creating kind cluster: $(KIND_CLUSTER) (with extraPortMappings)"; \
	  $(KIND) create cluster --name "$(KIND_CLUSTER)" --config "$(KIND_CONFIG_FILE)"; \
	fi

kind-down: ## Delete kind cluster (DANGEROUS) [CONFIRM=1]
> @if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
> @$(KIND) delete cluster --name "$(KIND_CLUSTER)"

# =========================================================
##@ ingress-nginx (kind optimized)
# =========================================================
.PHONY: ingress-ensure ingress-status ingress-clean ingress-reset

ingress-ensure: ## Ensure ingress-nginx installed (AUTO_INGRESS=1) [NodePort 30080/30443]
> @set -euo pipefail; \
	if [ "$(AUTO_INGRESS)" != "1" ]; then \
	  echo "==> ingress ensure skipped (AUTO_INGRESS=$(AUTO_INGRESS))"; \
	  exit 0; \
	fi; \
	$(MAKE) --no-print-directory guard-context; \
	test -f "$(INGRESS_VALUES_KIND)" || (echo "❌ missing: $(INGRESS_VALUES_KIND)" && exit 1); \
	echo "==> installing/upgrading ingress-nginx via helm (kind optimized)"; \
	$(HELM) repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true; \
	$(HELM) repo update >/dev/null 2>&1 || true; \
	$(HELM) upgrade --install "$(INGRESS_RELEASE)" "$(INGRESS_CHART)" \
	  -n "$(INGRESS_NS)" --create-namespace \
	  -f "$(INGRESS_VALUES_KIND)" \
	  --wait --timeout 10m; \
	echo "==> waiting ingress-nginx rollout"; \
	$(KUBECTL) rollout status -n "$(INGRESS_NS)" deploy/ingress-nginx-controller --timeout=10m

ingress-status: ## Show ingress-nginx svc/deploy
> @$(MAKE) --no-print-directory guard-context
> @$(KUBECTL) get deploy,svc -n $(INGRESS_NS) | sed -n '1,200p'

ingress-clean: ## Cleanup ingress-nginx leftovers (DANGEROUS) [CONFIRM=1]
> @if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
> @set -euo pipefail; \
	$(MAKE) --no-print-directory guard-context; \
	echo "==> deleting namespace $(INGRESS_NS) (if exists)"; \
	$(KUBECTL) delete ns "$(INGRESS_NS)" --wait >/dev/null 2>&1 || true; \
	echo "==> deleting cluster-scoped leftovers (filter: ingress-nginx)"; \
	cr="$$( $(KUBECTL) get clusterrole -o name | grep -E 'ingress-nginx|ingressnginx' || true )"; \
	crb="$$( $(KUBECTL) get clusterrolebinding -o name | grep -E 'ingress-nginx|ingressnginx' || true )"; \
	if [ -n "$$cr" ]; then echo "$$cr" | xargs -r $(KUBECTL) delete; else echo "  (no clusterrole matched)"; fi; \
	if [ -n "$$crb" ]; then echo "$$crb" | xargs -r $(KUBECTL) delete; else echo "  (no clusterrolebinding matched)"; fi; \
	echo "✅ ingress-nginx cleaned"

ingress-reset: ingress-clean ingress-ensure ## Cleanup then reinstall ingress-nginx (DANGEROUS) [CONFIRM=1]
> @echo "✅ ingress-nginx reset done"

# =========================================================
##@ /etc/hosts (optional)
# =========================================================
HOSTS_FILE ?= /etc/hosts
HOSTS_IP   ?= 127.0.0.1

.PHONY: hosts-ensure hosts-up hosts-down

hosts-ensure: ## Optionally ensure /etc/hosts has INGRESS_HOST -> 127.0.0.1 (AUTO_HOSTS=1; first time requires CONFIRM=1)
> @set -euo pipefail; \
>   hf="$(HOSTS_FILE)"; host="$(INGRESS_HOST)"; ip="$(HOSTS_IP)"; \
>   if [ "$(AUTO_HOSTS)" != "1" ]; then \
>     echo "==> hosts update skipped (AUTO_HOSTS=$(AUTO_HOSTS))"; \
>     echo "    If you want it: make hosts-up CONFIRM=1"; \
>     exit 0; \
>   fi; \
>   if sudo grep -qE "^[[:space:]]*$$ip[[:space:]]+$$host([[:space:]]|$$)" "$$hf"; then \
>     echo "✅ hosts already present: $$host -> $$ip"; \
>     exit 0; \
>   fi; \
>   if [ "$(CONFIRM)" != "1" ]; then \
>     echo "❌ Refusing to edit $$hf without CONFIRM=1 (needed once)"; \
>     echo "   Run: make hosts-up CONFIRM=1"; \
>     exit 1; \
>   fi; \
>   $(MAKE) --no-print-directory hosts-up CONFIRM=1

hosts-up: ## Add INGRESS_HOST to /etc/hosts (DANGEROUS) [CONFIRM=1]
> @set -euo pipefail; \
>   if [ "$(CONFIRM)" != "1" ]; then \
>     echo "❌ Refusing (dangerous). Run with CONFIRM=1"; \
>     exit 1; \
>   fi; \
>   hf="$(HOSTS_FILE)"; host="$(INGRESS_HOST)"; ip="$(HOSTS_IP)"; \
>   echo "==> ensuring hosts entry: $$host -> $$ip (file: $$hf)"; \
>   if sudo grep -qE "^[[:space:]]*$$ip[[:space:]]+$$host([[:space:]]|$$)" "$$hf"; then \
>     echo "✅ already present"; \
>     exit 0; \
>   fi; \
>   if sudo grep -qE "^[[:space:]]*[0-9.]+[[:space:]]+$$host([[:space:]]|$$)" "$$hf"; then \
>     echo "❌ $$host already exists with a different IP:"; \
>     sudo grep -nE "^[[:space:]]*[0-9.]+[[:space:]]+$$host([[:space:]]|$$)" "$$hf" || true; \
>     echo "   Please edit $$hf manually, then rerun."; \
>     exit 1; \
>   fi; \
>   ts="$$(date +%Y%m%d%H%M%S)"; \
>   echo "==> backup $$hf -> $$hf.bak.$$ts"; \
>   sudo cp -a "$$hf" "$$hf.bak.$$ts"; \
>   echo "$$ip $$host" | sudo tee -a "$$hf" >/dev/null; \
>   echo "✅ added: $$ip $$host"; \
>   (getent hosts "$$host" || true) | sed -n '1,2p' || true

hosts-down: ## Remove INGRESS_HOST from /etc/hosts (DANGEROUS) [CONFIRM=1]
> @set -euo pipefail; \
	if [ "$(CONFIRM)" != "1" ]; then \
	  echo "❌ Refusing (dangerous). Run with CONFIRM=1"; exit 1; \
	fi; \
	hf="$(HOSTS_FILE)"; host="$(INGRESS_HOST)"; \
	echo "==> removing hosts entry for: $$host (file: $$hf)"; \
	ts="$$(date +%Y%m%d%H%M%S)"; \
	echo "==> backup $$hf -> $$hf.bak.$$ts"; \
	sudo cp -a "$$hf" "$$hf.bak.$$ts"; \
	sudo awk -v h="$$host" ' \
	  /^[[:space:]]*#/ { print; next } \
	  NF==0 { print; next } \
	  $$1 !~ /^[0-9.]+$$/ && $$1 !~ /^[0-9A-Fa-f:]+(%[^[:space:]]+)?$$/ { print; next } \
	  { \
	    out=$$1; keep=0; \
	    for (i=2; i<=NF; i++) { \
	      if ($$i != h) { out=out " " $$i; keep=1 } \
	    } \
	    if (keep==1) print out; \
	  } \
	' "$$hf" | sudo tee "$$hf.tmp" >/dev/null; \
	sudo mv "$$hf.tmp" "$$hf"; \
	echo "✅ removed (if existed)"; \
	(getent -s files hosts "$$host" || true) | sed -n '1,2p' || true

# =========================================================
##@ Observability (Kustomize apply + wait)
# =========================================================
.PHONY: obs-ensure obs-up obs-wait obs-status obs-down

obs-ensure: ## Optionally apply observability stack via kustomize and wait (AUTO_OBS=1)
> @set -euo pipefail; \
	if [ "$(AUTO_OBS)" != "1" ]; then \
	  echo "==> observability ensure skipped (AUTO_OBS=$(AUTO_OBS))"; \
	  exit 0; \
	fi; \
	$(MAKE) --no-print-directory obs-up; \
	$(MAKE) --no-print-directory obs-wait; \
	$(MAKE) --no-print-directory obs-status

obs-up: ## Apply observability stack via kustomize (uses K8S_NAMESPACE)
> @$(MAKE) --no-print-directory guard-context
> @set -euo pipefail; \
	test -f "$(OBS_DIR)/kustomization.yaml" || (echo "❌ missing: $(OBS_DIR)/kustomization.yaml" && exit 1); \
	echo "==> kubectl apply -k $(OBS_DIR) -n $(K8S_NAMESPACE)"; \
	$(KUBECTL) apply -n $(K8S_NAMESPACE) -k $(OBS_DIR)

obs-wait: ## Wait until observability deployments are ready
> @$(MAKE) --no-print-directory guard-context
> @set -euo pipefail; \
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
> @$(MAKE) --no-print-directory guard-context
> @echo "== Pods =="; $(KUBECTL) get pods -n $(K8S_NAMESPACE) | egrep 'NAME|otel-collector|tempo|prometheus|grafana' || true
> @echo ""
> @echo "== Svc =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE) | egrep 'NAME|otel-collector|tempo|prometheus|grafana' || true

obs-down: ## Delete observability stack via kustomize (DANGEROUS) [CONFIRM=1]
> @$(MAKE) --no-print-directory guard-context
> @if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
> @set -euo pipefail; \
	echo "==> kubectl delete -k $(OBS_DIR) -n $(K8S_NAMESPACE)"; \
	$(KUBECTL) delete -n $(K8S_NAMESPACE) -k $(OBS_DIR) || true

# =========================================================
##@ Proto (kept)
# =========================================================
.PHONY: proto-preflight proto

proto-preflight: ## Check protoc + plugins exist
> @set -euo pipefail; \
	command -v $(PROTOC) >/dev/null 2>&1 || (echo "❌ missing command: $(PROTOC)" && exit 1); \
	command -v protoc-gen-go >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-go" && exit 1); \
	command -v protoc-gen-go-grpc >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-go-grpc" && exit 1); \
	command -v protoc-gen-grpc-gateway >/dev/null 2>&1 || (echo "❌ missing: protoc-gen-grpc-gateway" && exit 1); \
	echo "✅ protoc tools OK"

proto: proto-preflight ## Generate protobuf (go / go-grpc / grpc-gateway)
> @echo "==> Generating protobufs..."
> @for dir in $(PROTO_DIRS); do \
		echo " -> $$dir"; \
		$(PROTOC) \
		  -I . \
		  -I third_party \
		  --go_out=paths=source_relative:. \
		  --go-grpc_out=paths=source_relative:. \
		  $$dir/*.proto; \
	done
> @echo "==> Generating gRPC-Gateway..."
> @for file in $(GATEWAY_PROTOS); do \
		echo " -> $$file"; \
		$(PROTOC) \
		  -I . \
		  -I third_party \
		  --grpc-gateway_out=paths=source_relative,generate_unbound_methods=true:. \
		  $$file; \
	done

# =========================================================
##@ Helm (App)
# =========================================================
.PHONY: h-template h-lint h-status h-up h-up-wait h-rollback h-uninstall h-values h-manifest

h-template: check-values ## helm template
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) template $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) -f $(VALUES_FILE) --set global.imageTag=$(TAG)

h-lint: ## helm lint
> @$(HELM) lint $(CHART_DIR)

h-status: ## helm status
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) status $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-up: check-values ## helm upgrade --install (no wait)
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) upgrade --install $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) -f $(VALUES_FILE) --set global.imageTag=$(TAG)

h-up-wait: check-values ## helm upgrade --install --wait --timeout 5m --atomic
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) upgrade --install $(HELM_RELEASE) $(CHART_DIR) -n $(K8S_NAMESPACE) -f $(VALUES_FILE) --set global.imageTag=$(TAG) --wait --timeout 5m --atomic

h-rollback: ## helm rollback
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) rollback $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-uninstall: ## helm uninstall (DANGEROUS) [CONFIRM=1]
> @$(MAKE) --no-print-directory guard-context
> @if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
> @$(HELM) uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-values: ## helm get values -a
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) get values $(HELM_RELEASE) -n $(K8S_NAMESPACE) -a

h-manifest: ## helm get manifest
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) get manifest $(HELM_RELEASE) -n $(K8S_NAMESPACE)

# =========================================================
##@ kind rebuild (tag-safe end-to-end)
# =========================================================
.PHONY: k-load-grpc k-load-gw k-load k-rebuild-wait k-wait k-image-assert k-status

k-load-grpc: ## docker build grpc-echo:TAG -> kind load
> @$(DOCKER) build -t $(GRPC_IMAGE_REPO):$(TAG) .
> @$(KIND) load docker-image --name $(KIND_CLUSTER) $(GRPC_IMAGE_REPO):$(TAG)

k-load-gw: ## docker build grpc-http-gateway:TAG -> kind load
> @$(DOCKER) build -f Dockerfile.http_gateway -t $(GW_IMAGE_REPO):$(TAG) .
> @$(KIND) load docker-image --name $(KIND_CLUSTER) $(GW_IMAGE_REPO):$(TAG)

k-load: k-load-grpc k-load-gw ## Build both images and kind load both

k-wait: ## Wait rollout for grpc-echo and http-gateway
> @$(MAKE) --no-print-directory guard-context
> @$(KUBECTL) rollout status deploy/grpc-echo -n $(K8S_NAMESPACE)
> @$(KUBECTL) rollout status deploy/http-gateway -n $(K8S_NAMESPACE)

k-image-assert: ## Assert deployments are running expected tag (TAG=...)
> @$(MAKE) --no-print-directory guard-context
> @grpc_img="$$( $(KUBECTL) get deploy grpc-echo -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}' )"; \
	gw_img="$$( $(KUBECTL) get deploy http-gateway -n $(K8S_NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}' )"; \
	exp_grpc="$(GRPC_IMAGE_REPO):$(TAG)"; \
	exp_gw="$(GW_IMAGE_REPO):$(TAG)"; \
	echo "expect grpc  : $$exp_grpc"; \
	echo "actual grpc  : $$grpc_img"; \
	echo "expect gw    : $$exp_gw"; \
	echo "actual gw    : $$gw_img"; \
	[ "$$grpc_img" = "$$exp_grpc" ] && [ "$$gw_img" = "$$exp_gw" ] && echo "✅ image tag match" || (echo "❌ image tag mismatch" && exit 1)

k-status: ## Show pods/services/ingress
> @$(MAKE) --no-print-directory guard-context
> @echo "== Pods =="; $(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide
> @echo ""
> @echo "== Services =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE)
> @echo ""
> @echo "== Ingress =="; $(KUBECTL) get ingress -n $(K8S_NAMESPACE) || true

k-rebuild-wait: k-load h-up-wait k-wait k-image-assert k-status ## Build->kind load->helm up(wait/atomic)->rollout->assert->status
> @echo "✅ Deployed with TAG=$(TAG) (ENV=$(ENV))"

# =========================================================
##@ Smoke tests (DIRECT; no port-forward)
# =========================================================
SMOKE_HOST ?= $(INGRESS_HOST)

.PHONY: gp-maybe-smoke gp-smoke-direct smoke smoke-login smoke-todos

gp-maybe-smoke: ## If AUTO=1 then run direct smoke (fallback to localhost)
> @set -euo pipefail; \
	if [ "$(AUTO)" != "1" ]; then \
	  echo ""; \
	  echo "✅ gp completed (apps deployed)."; \
	  echo "Direct access: http://$(INGRESS_HOST):$(INGRESS_HTTP_PORT)/ (or http://localhost:$(INGRESS_HTTP_PORT)/)"; \
	  echo "Next: make smoke"; \
	  echo ""; \
	  exit 0; \
	fi; \
	$(MAKE) --no-print-directory gp-smoke-direct

gp-smoke-direct: ## Wait direct ingress, then smoke (fallback to localhost)
> @set -euo pipefail; \
	host="$(INGRESS_HOST)"; \
	base="http://$$host:$(INGRESS_HTTP_PORT)"; \
	echo "==> waiting ingress: $$base/"; \
	ok=0; \
	for i in $$(seq 1 120); do \
	  if curl -sS "$$base/" >/dev/null 2>&1; then ok=1; break; fi; \
	  sleep 0.25; \
	done; \
	if [ $$ok -ne 1 ]; then \
	  echo "⚠️ not reachable via $(INGRESS_HOST). Trying localhost..."; \
	  host="localhost"; \
	  base="http://$$host:$(INGRESS_HTTP_PORT)"; \
	  ok=0; \
	  for i in $$(seq 1 120); do \
	    if curl -sS "$$base/" >/dev/null 2>&1; then ok=1; break; fi; \
	    sleep 0.25; \
	  done; \
	fi; \
	if [ $$ok -ne 1 ]; then \
	  echo "❌ ingress not reachable on host:$(INGRESS_HTTP_PORT)."; \
	  echo "   Check: kind extraPortMappings + ingress-nginx NodePort + controller ready."; \
	  exit 1; \
	fi; \
	echo "✅ ingress reachable via $$host:$(INGRESS_HTTP_PORT)"; \
	$(MAKE) --no-print-directory smoke SMOKE_HOST="$$host"

smoke-login: ## Smoke: login via ingress and print token
> @echo "==> POST http://$(SMOKE_HOST):$(INGRESS_HTTP_PORT)/auth/login"
> @resp=$$(curl -sS http://$(SMOKE_HOST):$(INGRESS_HTTP_PORT)/auth/login \
	  -H "Content-Type: application/json" \
	  -d '{"username":"user-123","password":"password"}' || true); \
	if [ -z "$$resp" ]; then echo "❌ request failed."; exit 1; fi; \
	echo "$$resp"; \
	if command -v jq >/dev/null 2>&1; then \
	  echo "$$resp" | jq -r '.accessToken'; \
	else \
	  echo "$$resp" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'; \
	fi

smoke-todos: ## Smoke: list todos via ingress (auto token; retry 502/503)
> @set -euo pipefail; \
	host="$(SMOKE_HOST)"; \
	base="http://$$host:$(INGRESS_HTTP_PORT)"; \
	token="$${TOKEN:-}"; \
	if [ -z "$$token" ]; then \
	  resp=$$(curl -sS "$$base/auth/login" -H "Content-Type: application/json" -d '{"username":"user-123","password":"password"}' || true); \
	  if [ -z "$$resp" ]; then echo "❌ login failed."; exit 1; fi; \
	  if command -v jq >/dev/null 2>&1; then token=$$(echo "$$resp" | jq -r '.accessToken'); else token=$$(echo "$$resp" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'); fi; \
	fi; \
	echo "==> GET $$base/v1/todos"; \
	for i in $$(seq 1 80); do \
	  out=$$(curl -sS -w "\n%{http_code}" "$$base/v1/todos" -H "Authorization: Bearer $$token" || true); \
	  code="$$(echo "$$out" | tail -n1)"; body="$$(echo "$$out" | sed '$$d')"; \
	  if [ "$$code" = "200" ]; then \
	    echo "$$body" | (command -v jq >/dev/null 2>&1 && jq . || cat); \
	    exit 0; \
	  fi; \
	  if [ "$$code" = "502" ] || [ "$$code" = "503" ]; then \
	    sleep 0.25; \
	    continue; \
	  fi; \
	  echo "$$body"; \
	  echo "❌ unexpected status $$code"; \
	  exit 1; \
	done; \
	echo "❌ timed out waiting for upstream (still 502/503)"; \
	exit 1

smoke: smoke-todos ## Smoke: login + list todos via ingress

# =========================================================
##@ MySQL (Helm)
# =========================================================
.PHONY: mysql-up mysql-up-wait mysql-wait mysql-status mysql-logs mysql-shell mysql-init-check mysql-backup mysql-restore mysql-uninstall mysql-wipe

mysql-up: ## Deploy mysql (no wait)
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) upgrade --install $(MYSQL_RELEASE) $(MYSQL_CHART_DIR) -n $(K8S_NAMESPACE)

mysql-up-wait: ## Deploy mysql (wait/atomic)
> @$(MAKE) --no-print-directory guard-context
> @$(HELM) upgrade --install $(MYSQL_RELEASE) $(MYSQL_CHART_DIR) -n $(K8S_NAMESPACE) --wait --timeout 10m --atomic

mysql-wait: ## Wait mysql StatefulSet rollout
> @$(MAKE) --no-print-directory guard-context
> @$(KUBECTL) rollout status sts/$(MYSQL_RELEASE) -n $(K8S_NAMESPACE) --timeout=10m

mysql-status: ## Show mysql resources (sts/pod/svc/pvc)
> @$(MAKE) --no-print-directory guard-context
> @$(KUBECTL) get sts,pod,svc,pvc -n $(K8S_NAMESPACE) | egrep -n 'NAME|$(MYSQL_RELEASE)|data-$(MYSQL_RELEASE)' || true

mysql-logs: ## Tail mysql logs (sts/mysql)
> @$(MAKE) --no-print-directory guard-context
> @$(KUBECTL) logs -n $(K8S_NAMESPACE) -f sts/$(MYSQL_RELEASE) --tail=200

mysql-shell: ## Exec mysql client in mysql-0 (root)
> @$(MAKE) --no-print-directory guard-context
> @$(KUBECTL) exec -n $(K8S_NAMESPACE) -it $(MYSQL_POD) -- sh -lc 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD"'

mysql-init-check: ## Check init.sql applied (SHOW TABLES in grpcdb)
> @$(MAKE) --no-print-directory guard-context
> @$(KUBECTL) exec -n $(K8S_NAMESPACE) $(MYSQL_POD) -- sh -lc 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" -e "USE $(MYSQL_DB); SHOW TABLES;"'

mysql-backup: ## Backup DB to MYSQL_DUMP
> @$(MAKE) --no-print-directory guard-context
> @set -euo pipefail; \
	out="$(MYSQL_DUMP)"; \
	mkdir -p "$$(dirname "$$out")"; \
	$(KUBECTL) get pod -n $(K8S_NAMESPACE) $(MYSQL_POD) >/dev/null; \
	echo "==> mysqldump $(MYSQL_DB) from $(MYSQL_POD) -> $$out"; \
	$(KUBECTL) exec -n $(K8S_NAMESPACE) $(MYSQL_POD) -- sh -lc 'mysqldump -uroot -p"$$MYSQL_ROOT_PASSWORD" $(MYSQL_DB)' > "$$out"; \
	ls -lh "$$out"

mysql-restore: ## Restore DB from MYSQL_DUMP into MYSQL_DB
> @$(MAKE) --no-print-directory guard-context
> @set -euo pipefail; \
	in="$(MYSQL_DUMP)"; \
	test -f "$$in" || (echo "❌ dump not found: $$in" && exit 1); \
	$(KUBECTL) get pod -n $(K8S_NAMESPACE) $(MYSQL_POD) >/dev/null; \
	echo "==> restore $$in into $(MYSQL_DB) on $(MYSQL_POD)"; \
	$(KUBECTL) exec -n $(K8S_NAMESPACE) -i $(MYSQL_POD) -- sh -lc 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" $(MYSQL_DB)' < "$$in"; \
	echo "✅ restore done"

mysql-uninstall: ## Uninstall mysql release (DANGEROUS) [CONFIRM=1]
> @$(MAKE) --no-print-directory guard-context
> @if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
> @$(HELM) uninstall $(MYSQL_RELEASE) -n $(K8S_NAMESPACE)

mysql-wipe: ## Uninstall mysql release + delete PVCs (VERY DANGEROUS) [CONFIRM=1]
> @$(MAKE) --no-print-directory guard-context
> @if [ "$(CONFIRM)" != "1" ]; then echo "Refusing. Set CONFIRM=1 to proceed."; exit 1; fi
> @-$(HELM) uninstall $(MYSQL_RELEASE) -n $(K8S_NAMESPACE)
> @echo "==> deleting PVCs like data-$(MYSQL_RELEASE)-* in ns=$(K8S_NAMESPACE)"
> @p="$$( $(KUBECTL) get pvc -n $(K8S_NAMESPACE) --no-headers 2>/dev/null | awk '$$1 ~ /^data-$(MYSQL_RELEASE)-/ {print $$1}' )"; \
	if [ -z "$$p" ]; then echo "No PVCs found."; else echo "$$p" | xargs -r $(KUBECTL) delete pvc -n $(K8S_NAMESPACE); fi

# =========================================================
##@ Diagnostics
# =========================================================
.PHONY: diag
diag: ## Snapshot for troubleshooting (context/pods/svc/ingress/endpoints/events/helm)
> @set -euo pipefail; \
	echo "== kubectl context =="; $(KUBECTL) config current-context || true; \
	echo ""; \
	echo "== nodes =="; $(KUBECTL) get nodes -o wide || true; \
	echo ""; \
	echo "== pods (all) =="; $(KUBECTL) get pods -A -o wide || true; \
	echo ""; \
	echo "== svc (ns=$(K8S_NAMESPACE)) =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE) || true; \
	echo ""; \
	echo "== ingress (ns=$(K8S_NAMESPACE)) =="; $(KUBECTL) get ingress -n $(K8S_NAMESPACE) || true; \
	echo ""; \
	echo "== endpoints (ns=$(K8S_NAMESPACE)) =="; $(KUBECTL) get endpoints -n $(K8S_NAMESPACE) || true; \
	echo ""; \
	echo "== describe ingress http-gateway =="; $(KUBECTL) describe ingress http-gateway -n $(K8S_NAMESPACE) || true; \
	echo ""; \
	echo "== events (ns=$(K8S_NAMESPACE), last 40) =="; $(KUBECTL) get events -n $(K8S_NAMESPACE) --sort-by=.lastTimestamp | tail -n 40 || true; \
	echo ""; \
	echo "== helm status =="; \
	$(HELM) status $(HELM_RELEASE) -n $(K8S_NAMESPACE) || true; \
	$(HELM) status $(MYSQL_RELEASE) -n $(K8S_NAMESPACE) || true; \
	$(HELM) status $(INGRESS_RELEASE) -n $(INGRESS_NS) || true

# =========================================================
##@ Optional local dev (kept)
# =========================================================
.PHONY: fmt vet test build tree compose-up compose-down compose-logs compose-ps jwt jwt-print evans health

fmt: ## gofmt
> @echo "==> gofmt"
> @gofmt -w $$(find . -name '*.go' -not -path "./vendor/*")

vet: ## go vet
> @$(GO) vet ./...

test: ## go test
> @$(GO) test ./...

build: ## go build
> @$(GO) build ./...

tree: ## tree -L 4
> @tree -L 4

compose-up: ## docker compose up --build
> @$(DOCKER_COMPOSE) up --build

compose-down: ## docker compose down
> @$(DOCKER_COMPOSE) down

compose-logs: ## docker compose logs -f
> @$(DOCKER_COMPOSE) logs -f

compose-ps: ## docker compose ps
> @$(DOCKER_COMPOSE) ps

jwt-print: ## Print token only (cmd/jwt_gen)
> @cd cmd/jwt_gen && AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .

jwt: ## Print 'export TOKEN=...' for eval
> @set -euo pipefail; \
	token=$$(cd cmd/jwt_gen && AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .); \
	echo "export TOKEN=$$token"

evans: ## evans repl to gRPC (local port)
> @$(EVANS) --host $(word 1,$(subst :, ,$(GRPC_ADDR))) --port $(GRPC_PORT) -r repl

health: ## gRPC health check (local)
> @if [ -z "$(SERVICE)" ]; then \
		$(GRPCURL) -plaintext -d '{}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	else \
		$(GRPCURL) -plaintext -d '{"service":"$(SERVICE)"}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	fi
