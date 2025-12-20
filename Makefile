# ---------- Config ----------
GO        ?= go
GO_RUN    ?= $(GO) run
GRPCURL   ?= grpcurl
DOCKER_COMPOSE ?= docker-compose
GRPC_ADDR ?= localhost:50051
SERVICE   ?=

# Kubernetes / kind
KUBECTL       ?= kubectl
K8S_NAMESPACE ?= default
KIND_CLUSTER  ?= grpc-echo   # kind クラスタ名

# プロトファイルディレクトリ自動検出
PROTO_DIRS := $(shell find api -name '*.proto' -exec dirname {} \; | sort -u)

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
	# Todoサービスだけ Gateway を生成
	protoc \
	  -I . \
	  -I third_party \
	  --grpc-gateway_out=paths=source_relative,generate_unbound_methods=true:. \
	  api/todo/v1/todo.proto

# ---------- Run (Local) ----------
.PHONY: run-server
run-server:
	$(GO_RUN) ./cmd/server
	
# ---------- Docker ----------
.PHONY: docker-build docker-run docker-stop
docker-build:
	docker build -t grpc-echo .

docker-run:
	docker run --rm -p 50051:50051 --name grpc-echo grpc-echo

docker-stop:
	-docker stop grpc-echo || true

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

# ---------- Tools ----------
.PHONY: fmt vet lint tree
fmt:
	gofmt -w $$(find . -name '*.go' -not -path "./vendor/*")

vet:
	$(GO) vet ./...

lint: fmt vet

tree:
	tree -L 3

# ---------- Testing ----------
.PHONY: test build
test:
	$(GO) test ./...

build:
	$(GO) build ./...

# ---------- DB Utility (docker-compose 用) ----------
.PHONY: db
db:
	$(DOCKER_COMPOSE) exec db mysql -uapp -papp grpcdb

# ---------- Health ----------
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
	evans --host localhost --port 50051 -r repl

# ---------- HTTP Gateway (ローカル用) ----------
.PHONY: run-gateway
run-gateway:
	$(GO_RUN) ./cmd/http_gateway

# ---------- Kubernetes Utility ----------
.PHONY: k-build k-pods k-grpc k-graf k-graf-logs \
        k-mysql-logs k-otel-logs k-mysql k-mysql-sh

# gRPC サーバ用イメージをビルド → kind にロード → Deployment 再起動
k-build:
	docker build -t grpc-echo:latest .
	kind load docker-image --name $(KIND_CLUSTER) grpc-echo:latest
	$(KUBECTL) rollout restart deployment grpc-echo -n $(K8S_NAMESPACE)
	$(KUBECTL) get pods -l app=grpc-echo -n $(K8S_NAMESPACE)

# Pod 一覧確認
k-pods:
	$(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide

# gRPC サービスを localhost:50051 にポートフォワード
k-grpc:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo 50051:50051

# Grafana を localhost:3000 にポートフォワード
k-graf:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grafana 3000:3000

# Grafana のログ監視
k-graf-logs:
	$(KUBECTL) logs deploy/grafana -n $(K8S_NAMESPACE) -f

# MySQL のログ監視
k-mysql-logs:
	$(KUBECTL) logs deploy/mysql -n $(K8S_NAMESPACE) -f

# OpenTelemetry Collector のログ監視
k-otel-logs:
	$(KUBECTL) logs deploy/otel-collector -n $(K8S_NAMESPACE) -f

# MySQL に直接ログイン（root/root, grpcdb）
k-mysql:
	$(KUBECTL) exec -it -n $(K8S_NAMESPACE) \
	  $$($(KUBECTL) get pod -l app=mysql -n $(K8S_NAMESPACE) -o jsonpath='{.items[0].metadata.name}') \
	  -- mysql -uroot -proot grpcdb

# MySQL Pod のシェルに入る
k-mysql-sh:
	$(KUBECTL) exec -it -n $(K8S_NAMESPACE) \
	  $$($(KUBECTL) get pod -l app=mysql -n $(K8S_NAMESPACE) -o jsonpath='{.items[0].metadata.name}') \
	  -- bash
