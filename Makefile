# ---------- Config ----------
GO          ?= go
GO_RUN      ?= $(GO) run
GO_BUILD    ?= $(GO) build
GRPCURL     ?= grpcurl
DOCKER      ?= docker
DOCKER_COMPOSE ?= docker-compose
KUBECTL     ?= kubectl
HELM        ?= helm
KIND        ?= kind

# ---------- Addresses (Local access) ----------
GRPC_ADDR          ?= localhost:50051
HTTP_GATEWAY_ADDR  ?= localhost:8081
METRICS_ADDR       ?= localhost:9464

GRPC_HOST          := $(word 1,$(subst :, ,$(GRPC_ADDR)))
GRPC_PORT          := $(word 2,$(subst :, ,$(GRPC_ADDR)))

HTTP_GATEWAY_HOST  := $(word 1,$(subst :, ,$(HTTP_GATEWAY_ADDR)))
HTTP_GATEWAY_PORT  := $(word 2,$(subst :, ,$(HTTP_GATEWAY_ADDR)))

METRICS_HOST       := $(word 1,$(subst :, ,$(METRICS_ADDR)))
METRICS_PORT       := $(word 2,$(subst :, ,$(METRICS_ADDR)))

SERVICE   ?=

# ---------- Kubernetes / kind ----------
K8S_NAMESPACE ?= default
KIND_CLUSTER  ?= grpc-echo

# Ingress (kind + ingress-nginx)
INGRESS_NS          ?= ingress-nginx
INGRESS_SVC         ?= ingress-nginx-controller
INGRESS_LOCAL_PORT  ?= 8080
INGRESS_HOST        ?= grpc-echo.local
INGRESS_URL         ?= http://$(INGRESS_HOST):$(INGRESS_LOCAL_PORT)

# ---------- Helm ----------
HELM_RELEASE ?= grpc-echo
HELM_CHART   ?= ./helm/grpc-echo
# default values (dev)
HELM_VALUES  ?= $(HELM_CHART)/values.dev.yaml

# ---------- Images ----------
# tag is the main "switch" to avoid latest-hell.
IMAGE_TAG ?= dev

GRPC_IMAGE ?= grpc-echo:$(IMAGE_TAG)
GW_IMAGE   ?= grpc-http-gateway:$(IMAGE_TAG)

# ---------- JWT ----------
JWT_SECRET ?= my-dev-secret-key

# ---------- Protobuf ----------
PROTO_DIRS := $(shell find api -name '*.proto' -exec dirname {} \; | sort -u)
GATEWAY_PROTOS := $(shell find api -name '*.proto' -print)

# ---------- Helpers ----------
# Usage: $(call pod,app=mysql)
define pod
$(shell $(KUBECTL) get pod -n $(K8S_NAMESPACE) -l $(1) -o jsonpath='{.items[0].metadata.name}')
endef

# base64 decode: linux/WSL uses -d, mac uses -D. try both.
BASE64_DECODE = (base64 -d 2>/dev/null || base64 -D)

# ---------- Protobuf / gRPC-Gateway ----------
.PHONY: proto
proto:
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
.PHONY: run-server run-gateway
run-server:
	$(GO_RUN) ./cmd/server

run-gateway:
	$(GO_RUN) ./cmd/http_gateway

# ---------- Build (Go) ----------
.PHONY: build test fmt vet lint tree
build:
	$(GO) build ./...

test:
	$(GO) test ./...

fmt:
	@echo "==> gofmt all *.go"
	@gofmt -w $$(find . -name '*.go' -not -path "./vendor/*")

vet:
	$(GO) vet ./...

lint: fmt vet

tree:
	tree -L 3

# ---------- Docker ----------
.PHONY: docker-build docker-build-gw docker-run docker-run-gw docker-stop docker-stop-gw
docker-build:
	$(DOCKER) build -t $(GRPC_IMAGE) .

docker-build-gw:
	$(DOCKER) build -f Dockerfile.http_gateway -t $(GW_IMAGE) .

docker-run:
	$(DOCKER) run --rm -p $(GRPC_PORT):50051 --name grpc-echo $(GRPC_IMAGE)

docker-run-gw:
	$(DOCKER) run --rm \
	  -p $(HTTP_GATEWAY_PORT):8081 \
	  -e GRPC_SERVER_ADDR=$(GRPC_ADDR) \
	  -e HTTP_LISTEN_ADDR=:8081 \
	  --name grpc-http-gateway \
	  $(GW_IMAGE)

docker-stop:
	- $(DOCKER) stop grpc-echo || true

docker-stop-gw:
	- $(DOCKER) stop grpc-http-gateway || true

# ---------- Docker Compose ----------
.PHONY: compose-build compose-db compose-down compose-logs compose-ps
compose-build:
	$(DOCKER_COMPOSE) up --build

compose-db:
	$(DOCKER_COMPOSE) up -d db

compose-down:
	$(DOCKER_COMPOSE) down

compose-logs:
	$(DOCKER_COMPOSE) logs -f

compose-ps:
	$(DOCKER_COMPOSE) ps

# ---------- Health / Tools ----------
.PHONY: health evans
health:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Checking overall health..."; \
		$(GRPCURL) -plaintext -d '{}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	else \
		echo "Checking service: $(SERVICE)"; \
		$(GRPCURL) -plaintext -d '{"service":"$(SERVICE)"}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	fi

evans:
	evans --host $(GRPC_HOST) --port $(GRPC_PORT) -r repl

# ---------- Helm (kind+helm main flow) ----------
.PHONY: h-install h-up h-template h-status
h-install:
	$(HELM) install $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE) -f $(HELM_VALUES)

# upgrade --install (idempotent)
h-up:
	$(HELM) upgrade --install $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE) -f $(HELM_VALUES)

h-template:
	$(HELM) template $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE) -f $(HELM_VALUES)

h-status:
	$(HELM) status $(HELM_RELEASE) -n $(K8S_NAMESPACE)

# ---------- kind helpers ----------
.PHONY: k-load k-load-gw
k-load:
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GRPC_IMAGE)

k-load-gw:
	$(KIND) load docker-image --name $(KIND_CLUSTER) $(GW_IMAGE)

# ---------- Kubernetes (observability / debugging) ----------
.PHONY: k-pods k-status k-apply k-del-pods k-env
k-pods:
	$(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide

k-status:
	@echo "== Pods =="; $(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide
	@echo "== Services =="; $(KUBECTL) get svc -n $(K8S_NAMESPACE)
	@echo "== Ingress =="; $(KUBECTL) get ingress -n $(K8S_NAMESPACE) || true

k-apply:
	@if [ -z "$(FILE)" ]; then \
	  echo "Applying manifests under k8s/"; \
	  $(KUBECTL) apply -n $(K8S_NAMESPACE) -f k8s/; \
	else \
	  echo "Applying $(FILE)"; \
	  $(KUBECTL) apply -n $(K8S_NAMESPACE) -f $(FILE); \
	fi

k-del-pods:
	@if [ -z "$(SEL)" ]; then \
	  echo "Usage: make k-del-pods SEL=\"app=mysql\""; exit 1; \
	fi
	$(KUBECTL) delete pod -l $(SEL) -n $(K8S_NAMESPACE)

k-env:
	$(KUBECTL) get deploy grpc-echo -n $(K8S_NAMESPACE) -o yaml \
	  | sed -n '/envFrom:/,/imagePullPolicy/p'

# ---------- kubectl logs / wait ----------
.PHONY: k-grpc-logs k-gw-logs k-otel-logs k-mysql-logs k-logs k-wait
k-grpc-logs:
	$(KUBECTL) logs deploy/grpc-echo -n $(K8S_NAMESPACE) -f

k-gw-logs:
	$(KUBECTL) logs deploy/http-gateway -n $(K8S_NAMESPACE) -f

k-otel-logs:
	$(KUBECTL) logs deploy/otel-collector -n $(K8S_NAMESPACE) -f

k-mysql-logs:
	$(KUBECTL) logs deploy/mysql -n $(K8S_NAMESPACE) -f

# follow both main apps (useful)
k-logs:
	@echo "== grpc-echo =="; \
	$(KUBECTL) logs deploy/grpc-echo -n $(K8S_NAMESPACE) -f & \
	echo "== http-gateway =="; \
	$(KUBECTL) logs deploy/http-gateway -n $(K8S_NAMESPACE) -f; \
	wait

k-wait:
	$(KUBECTL) rollout status deploy/grpc-echo -n $(K8S_NAMESPACE) --timeout=120s
	$(KUBECTL) rollout status deploy/http-gateway -n $(K8S_NAMESPACE) --timeout=120s

# ---------- Port-forward (debug) ----------
.PHONY: k-grpc k-gw k-metrics k-graf
k-grpc:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo $(GRPC_PORT):50051

k-gw:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/http-gateway $(HTTP_GATEWAY_PORT):8081

k-metrics:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo $(METRICS_PORT):9464

k-graf:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grafana 3000:3000

# ---------- Ingress (main dev entry for kind+helm) ----------
.PHONY: k-ingress k-ingress-url
k-ingress:
	$(KUBECTL) port-forward -n $(INGRESS_NS) svc/$(INGRESS_SVC) $(INGRESS_LOCAL_PORT):80

k-ingress-url:
	@echo "$(INGRESS_URL)"

# ---------- DB (k8s) ----------
.PHONY: k-mysql k-mysql-sh
k-mysql:
	$(KUBECTL) exec -it -n $(K8S_NAMESPACE) $(call pod,app=mysql) -- mysql -uroot -proot grpcdb

k-mysql-sh:
	$(KUBECTL) exec -it -n $(K8S_NAMESPACE) $(call pod,app=mysql) -- bash

# ---------- Secret / ConfigMap ----------
.PHONY: k-cm k-secret k-secret-decode
k-cm:
	$(KUBECTL) get configmap grpc-echo-config -n $(K8S_NAMESPACE) -o yaml

k-secret:
	$(KUBECTL) get secret grpc-echo-secret -n $(K8S_NAMESPACE) -o yaml

k-secret-decode:
	@echo "DB_USER: $$($(KUBECTL) get secret grpc-echo-secret -n $(K8S_NAMESPACE) -o jsonpath='{.data.DB_USER}' | $(BASE64_DECODE))"
	@echo "DB_PASSWORD: $$($(KUBECTL) get secret grpc-echo-secret -n $(K8S_NAMESPACE) -o jsonpath='{.data.DB_PASSWORD}' | $(BASE64_DECODE))"
	@echo "AUTH_SECRET: $$($(KUBECTL) get secret grpc-echo-secret -n $(K8S_NAMESPACE) -o jsonpath='{.data.AUTH_SECRET}' | $(BASE64_DECODE))"

# ---------- One-shot workflows (kind+helm) ----------
.PHONY: k-rebuild k-rebuild-grpc k-rebuild-gw
# grpc + gateway build -> kind load -> helm upgrade -> wait
k-rebuild:
	$(MAKE) docker-build IMAGE_TAG=$(IMAGE_TAG)
	$(MAKE) docker-build-gw IMAGE_TAG=$(IMAGE_TAG)
	$(MAKE) k-load IMAGE_TAG=$(IMAGE_TAG)
	$(MAKE) k-load-gw IMAGE_TAG=$(IMAGE_TAG)
	$(MAKE) h-up
	$(MAKE) k-wait

k-rebuild-grpc:
	$(MAKE) docker-build IMAGE_TAG=$(IMAGE_TAG)
	$(MAKE) k-load IMAGE_TAG=$(IMAGE_TAG)
	$(MAKE) h-up
	$(MAKE) k-wait

k-rebuild-gw:
	$(MAKE) docker-build-gw IMAGE_TAG=$(IMAGE_TAG)
	$(MAKE) k-load-gw IMAGE_TAG=$(IMAGE_TAG)
	$(MAKE) h-up
	$(MAKE) k-wait

# ---------- JWT Helper ----------
.PHONY: jwt jwt-print
jwt-print:
	cd cmd/jwt_gen && AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .

jwt:
	@cd cmd/jwt_gen && \
	  token=$$(AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .); \
	  echo "export TOKEN=$$token"
