SHELL := /usr/bin/env bash

# ---------- Basic ----------
GO              ?= go
GO_RUN          ?= $(GO) run
GO_BUILD        ?= $(GO) build
GRPCURL         ?= grpcurl
DOCKER_COMPOSE  ?= docker-compose
KUBECTL         ?= kubectl
HELM            ?= helm
KIND            ?= kind

K8S_NAMESPACE   ?= default
KIND_CLUSTER    ?= grpc-echo

# ---------- Addresses (local) ----------
GRPC_ADDR          ?= localhost:50051
HTTP_GATEWAY_ADDR  ?= localhost:8081
METRICS_ADDR       ?= localhost:9464

GRPC_HOST          := $(word 1,$(subst :, ,$(GRPC_ADDR)))
GRPC_PORT          := $(word 2,$(subst :, ,$(GRPC_ADDR)))

HTTP_GATEWAY_HOST  := $(word 1,$(subst :, ,$(HTTP_GATEWAY_ADDR)))
HTTP_GATEWAY_PORT  := $(word 2,$(subst :, ,$(HTTP_GATEWAY_ADDR)))

METRICS_HOST       := $(word 1,$(subst :, ,$(METRICS_ADDR)))
METRICS_PORT       := $(word 2,$(subst :, ,$(METRICS_ADDR)))

SERVICE ?=

# ---------- JWT ----------
JWT_SECRET ?= my-dev-secret-key

# ---------- Protobuf ----------
PROTO_DIRS := $(shell find api -name '*.proto' -exec dirname {} \; | sort -u)
GATEWAY_PROTOS := $(shell find api -name '*.proto' -print)

# ---------- Helm / Chart ----------
HELM_RELEASE ?= grpc-echo
HELM_CHART   ?= ./helm/grpc-echo
# デフォルトは dev values（必要なら `make h-up HELM_VALUES=...` で差し替え）
HELM_VALUES  ?= ./helm/grpc-echo/values.dev.yaml

# ---------- Images / Tags ----------
GRPC_IMAGE_REPO ?= grpc-echo
GW_IMAGE_REPO   ?= grpc-http-gateway

# IMAGE_TAG を指定しない場合は:
# 1) git の short sha が取れればそれ
# 2) なければ日時
IMAGE_TAG ?= $(shell (git rev-parse --short HEAD 2>/dev/null) || date +%Y%m%d%H%M%S)

# ---------- Help ----------
.PHONY: help
help: ## Show help
	@echo ""
	@echo "Usage:"
	@echo "  make <target> [VAR=value]"
	@echo ""
	@echo "Common vars:"
	@echo "  IMAGE_TAG=$(IMAGE_TAG)"
	@echo "  HELM_VALUES=$(HELM_VALUES)"
	@echo "  K8S_NAMESPACE=$(K8S_NAMESPACE)"
	@echo "  KIND_CLUSTER=$(KIND_CLUSTER)"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_.-]+:.*## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*## "}; {printf "  %-24s %s\n", $$1, $$2}'
	@echo ""

# ---------- Protobuf / gRPC-Gateway ----------
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

# ---------- Run (Local) ----------
.PHONY: run-server build-server run-gateway
run-server: ## Run gRPC server locally
	$(GO_RUN) ./cmd/server

build-server: ## Build gRPC server binary
	$(GO_BUILD) ./cmd/server

run-gateway: ## Run HTTP gateway locally
	$(GO_RUN) ./cmd/http_gateway

# ---------- Docker ----------
.PHONY: docker-build docker-build-gw docker-run docker-run-gw docker-stop docker-stop-gw
docker-build: ## Build grpc-echo image (tag=IMAGE_TAG)
	docker build -t $(GRPC_IMAGE_REPO):$(IMAGE_TAG) .

docker-build-gw: ## Build http-gateway image (tag=IMAGE_TAG)
	docker build -f Dockerfile.http_gateway -t $(GW_IMAGE_REPO):$(IMAGE_TAG) .

docker-run: ## Run grpc-echo container locally (tag=IMAGE_TAG)
	docker run --rm \
	  -p $(GRPC_PORT):50051 \
	  --name grpc-echo \
	  $(GRPC_IMAGE_REPO):$(IMAGE_TAG)

docker-run-gw: ## Run http-gateway container locally (tag=IMAGE_TAG)
	docker run --rm \
	  -p $(HTTP_GATEWAY_PORT):8081 \
	  -e GRPC_SERVER_ADDR=$(GRPC_ADDR) \
	  -e HTTP_LISTEN_ADDR=:8081 \
	  --name grpc-http-gateway \
	  $(GW_IMAGE_REPO):$(IMAGE_TAG)

docker-stop: ## Stop grpc-echo container
	- docker stop grpc-echo >/dev/null 2>&1 || true

docker-stop-gw: ## Stop http-gateway container
	- docker stop grpc-http-gateway >/dev/null 2>&1 || true

# ---------- Docker Compose ----------
.PHONY: compose-up compose-db compose-down compose-logs compose-ps
compose-up: ## docker-compose up --build
	$(DOCKER_COMPOSE) up --build

compose-db: ## docker-compose up -d db
	$(DOCKER_COMPOSE) up -d db

compose-down: ## docker-compose down
	$(DOCKER_COMPOSE) down

compose-logs: ## docker-compose logs -f
	$(DOCKER_COMPOSE) logs -f

compose-ps: ## docker-compose ps
	$(DOCKER_COMPOSE) ps

# ---------- Tools ----------
.PHONY: fmt vet lint test build tree
fmt: ## gofmt all *.go
	@echo "==> gofmt all *.go"
	@gofmt -w $$(find . -name '*.go' -not -path "./vendor/*")

vet: ## go vet ./...
	$(GO) vet ./...

lint: fmt vet ## fmt + vet

test: ## go test ./...
	$(GO) test ./...

build: ## go build ./...
	$(GO) build ./...

tree: ## tree -L 3
	tree -L 3

# ---------- Health / REPL ----------
.PHONY: health evans
health: ## gRPC health check (SERVICE=... optional)
	@if [ -z "$(SERVICE)" ]; then \
		echo "Checking overall health..."; \
		$(GRPCURL) -plaintext -d '{}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	else \
		echo "Checking service: $(SERVICE)"; \
		$(GRPCURL) -plaintext -d '{"service":"$(SERVICE)"}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	fi

evans: ## evans repl to gRPC
	evans --host $(GRPC_HOST) --port $(GRPC_PORT) -r repl

# ---------- JWT Helper ----------
.PHONY: jwt jwt-print
jwt-print: ## Print token only
	cd cmd/jwt_gen && AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .

jwt: ## Print 'export TOKEN=...' for eval
	@cd cmd/jwt_gen && \
	  token=$$(AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .); \
	  echo "export TOKEN=$$token"

# ---------- Helm ----------
.PHONY: h-template h-lint h-install h-up h-status h-uninstall
h-template: ## helm template (HELM_VALUES=...)
	$(HELM) template $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE) -f $(HELM_VALUES)

h-lint: ## helm lint
	$(HELM) lint $(HELM_CHART)

h-install: ## helm install (first time)
	$(HELM) install $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE) -f $(HELM_VALUES)

# ★ここが主役：values のキーに合わせて image tag を自動で付与
h-up: ## helm upgrade (auto set grpcEcho/gateway image repo+tag by IMAGE_TAG)
	$(HELM) upgrade $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE) -f $(HELM_VALUES) \
	  --set grpcEcho.image.repository=$(GRPC_IMAGE_REPO) \
	  --set grpcEcho.image.tag=$(IMAGE_TAG) \
	  --set gateway.image.repository=$(GW_IMAGE_REPO) \
	  --set gateway.image.tag=$(IMAGE_TAG)

h-status: ## helm status
	$(HELM) status $(HELM_RELEASE) -n $(K8S_NAMESPACE)

h-uninstall: ## helm uninstall
	$(HELM) uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE)

# ---------- Kubernetes (kind) ----------
.PHONY: k-status k-pods k-svc k-ing k-logs k-apply k-del-pods \
        k-grpc k-gw k-metrics k-graf k-otel-logs k-mysql k-mysql-logs \
        k-ingress k-ingress-logs k-ingress-pf

k-status: ## Show pods/services/ingress
	@echo "== Pods =="; $(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide
	@echo ""
	@echo "== Services =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE)
	@echo ""
	@echo "== Ingress =="; $(KUBECTL) get ingress -n $(K8S_NAMESPACE) || true

k-pods: ## kubectl get pods -o wide
	$(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide

k-svc: ## kubectl get svc
	$(KUBECTL) get svc -n $(K8S_NAMESPACE)

k-ing: ## kubectl get ingress
	$(KUBECTL) get ingress -n $(K8S_NAMESPACE) || true

k-logs: ## Tail logs (APP=grpc-echo|http-gateway|mysql|...)
	@if [ -z "$(APP)" ]; then echo "Usage: make k-logs APP=grpc-echo"; exit 1; fi
	$(KUBECTL) logs deploy/$(APP) -n $(K8S_NAMESPACE) -f

k-apply: ## Apply manifests under k8s/ (or FILE=...)
	@if [ -z "$(FILE)" ]; then \
	  echo "Applying manifests under k8s/"; \
	  $(KUBECTL) apply -n $(K8S_NAMESPACE) -f k8s/; \
	else \
	  echo "Applying $(FILE)"; \
	  $(KUBECTL) apply -n $(K8S_NAMESPACE) -f $(FILE); \
	fi

k-del-pods: ## Delete pods by label selector (SEL="app=mysql")
	@if [ -z "$(SEL)" ]; then \
	  echo 'Usage: make k-del-pods SEL="app=mysql"'; exit 1; \
	fi
	$(KUBECTL) delete pod -l $(SEL) -n $(K8S_NAMESPACE)

# Port-forward: direct services
k-grpc: ## port-forward grpc-echo service (grpc)
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo $(GRPC_PORT):50051

k-gw: ## port-forward http-gateway service
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/http-gateway $(HTTP_GATEWAY_PORT):8081

k-metrics: ## port-forward metrics
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo $(METRICS_PORT):9464

k-graf: ## port-forward grafana (localhost:3000)
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grafana 3000:3000

# Ingress NGINX helpers
k-ingress: ## get ingress-nginx pods/svc
	$(KUBECTL) get pods,svc -n ingress-nginx -o wide

k-ingress-logs: ## tail ingress-nginx controller logs
	$(KUBECTL) logs -n ingress-nginx deploy/ingress-nginx-controller -f

k-ingress-pf: ## port-forward ingress-nginx controller to localhost:8080
	$(KUBECTL) port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80

# MySQL helpers
k-mysql: ## login mysql inside k8s (root/root, grpcdb)
	$(KUBECTL) exec -it -n $(K8S_NAMESPACE) \
	  $$($(KUBECTL) get pod -l app=mysql -n $(K8S_NAMESPACE) -o jsonpath='{.items[0].metadata.name}') \
	  -- mysql -uroot -proot grpcdb

k-mysql-logs: ## tail mysql logs
	$(KUBECTL) logs deploy/mysql -n $(K8S_NAMESPACE) -f

k-otel-logs: ## tail otel-collector logs
	$(KUBECTL) logs deploy/otel-collector -n $(K8S_NAMESPACE) -f

# ---------- kind load / rebuild with guaranteed tag ----------
.PHONY: k-load k-wait k-rebuild

k-load: ## kind load grpc-echo & http-gateway images (tag=IMAGE_TAG)
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GRPC_IMAGE_REPO):$(IMAGE_TAG)
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GW_IMAGE_REPO):$(IMAGE_TAG)

k-wait: ## Wait rollout for grpc-echo and http-gateway
	$(KUBECTL) rollout status deploy/grpc-echo -n $(K8S_NAMESPACE)
	$(KUBECTL) rollout status deploy/http-gateway -n $(K8S_NAMESPACE)

# ★これが “確実にそのタグで動く” まで面倒を見るワンショット
k-rebuild: docker-build docker-build-gw k-load h-up k-wait k-status ## Build->kind load->helm upgrade->wait->status
	@echo ""
	@echo "✅ Rebuilt and deployed with IMAGE_TAG=$(IMAGE_TAG)"
