# ---------- Config ----------
GO          ?= go
GO_RUN      ?= $(GO) run
GO_BUILD    ?= $(GO) build
GRPCURL     ?= grpcurl
DOCKER_COMPOSE ?= docker-compose

# gRPC / HTTP / Metrics のローカルアクセス用アドレス
GRPC_ADDR          ?= localhost:50051
HTTP_GATEWAY_ADDR  ?= localhost:8081
METRICS_ADDR       ?= localhost:9464

# アドレスから host / port を分解（grpcurl 用などに便利）
GRPC_HOST          := $(word 1,$(subst :, ,$(GRPC_ADDR)))
GRPC_PORT          := $(word 2,$(subst :, ,$(GRPC_ADDR)))

HTTP_GATEWAY_HOST  := $(word 1,$(subst :, ,$(HTTP_GATEWAY_ADDR)))
HTTP_GATEWAY_PORT  := $(word 2,$(subst :, ,$(HTTP_GATEWAY_ADDR)))

METRICS_HOST       := $(word 1,$(subst :, ,$(METRICS_ADDR)))
METRICS_PORT       := $(word 2,$(subst :, ,$(METRICS_ADDR)))

SERVICE   ?=

# Kubernetes / kind
KUBECTL       ?= kubectl
K8S_NAMESPACE ?= default
KIND_CLUSTER  ?= grpc-echo   # kind クラスタ名

# JWT
JWT_SECRET ?= my-dev-secret-key

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

.PHONY: build-server
build-server:
	$(GO_BUILD) ./cmd/server

# ---------- Docker ----------
.PHONY: docker-build docker-run docker-stop
docker-build:
	docker build -t grpc-echo:latest .

# ホスト側ポートは GRPC_ADDR から取得、コンテナ内は 50051 で固定
docker-run:
	docker run --rm \
	  -p $(GRPC_PORT):50051 \
	  --name grpc-echo \
	  grpc-echo

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
	evans --host $(GRPC_HOST) --port $(GRPC_PORT) -r repl

# ---------- HTTP Gateway (ローカル用) ----------
.PHONY: run-gateway
run-gateway:
	$(GO_RUN) ./cmd/http_gateway

# ---------- Kubernetes Utility ----------
.PHONY: k-build k-pods k-grpc k-grpc-logs \
        k-gw k-gw-logs \
        k-graf k-graf-logs \
        k-mysql-logs k-otel-logs k-mysql k-mysql-sh \
        k-apply k-del-pods k-auth k-metrics

# gRPC サーバ用イメージをビルド → kind にロード → Deployment 再起動
k-build:
	docker build -t grpc-echo:latest .
	kind load docker-image --name $(KIND_CLUSTER) grpc-echo:latest
	$(KUBECTL) rollout restart deployment grpc-echo -n $(K8S_NAMESPACE)
	$(KUBECTL) get pods -l app=grpc-echo -n $(K8S_NAMESPACE)

# Pod 一覧確認
k-pods:
	$(KUBECTL) get pods -n $(K8S_NAMESPACE) -o wide

# gRPC サービスを localhost:GRPC_PORT にポートフォワード
# （Service 側は常に 50051）
k-grpc:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo $(GRPC_PORT):50051

# gRPC サービス(grpc-echo)のログ監視
k-grpc-logs:
	$(KUBECTL) logs deploy/grpc-echo -n $(K8S_NAMESPACE) -f

# HTTP Gateway を localhost:HTTP_GATEWAY_PORT にポートフォワード
# （Service 側は常に 8081）
k-gw:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/http-gateway $(HTTP_GATEWAY_PORT):8081

# HTTP Gateway のログ監視
k-gw-logs:
	$(KUBECTL) logs deploy/http-gateway -n $(K8S_NAMESPACE) -f

# Grafana を localhost:3000 にポートフォワード
k-graf:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grafana 3000:3000

# Grafana のログ監視
k-graf-logs:
	$(KUBECTL) logs deploy/grafana -n $(K8S_NAMESPACE) -f

# OpenTelemetry Collector のログ監視 (follow)
k-otel-logs:
	$(KUBECTL) logs deploy/otel-collector -n $(K8S_NAMESPACE) -f

# メトリクス用ポートフォワード（ホスト側は METRICS_PORT）
# Service 側は常に 9464
k-metrics:
	$(KUBECTL) port-forward -n $(K8S_NAMESPACE) svc/grpc-echo $(METRICS_PORT):9464

# MySQL に直接ログイン（root/root, grpcdb）
k-mysql:
	$(KUBECTL) exec -it -n $(K8S_NAMESPACE) \
	  $$($(KUBECTL) get pod -l app=mysql -n $(K8S_NAMESPACE) -o jsonpath='{.items[0].metadata.name}') \
	  -- mysql -uroot -proot grpcdb

# MySQL のログ監視
k-mysql-logs:
	$(KUBECTL) logs deploy/mysql -n $(K8S_NAMESPACE) -f

# MySQL Pod のシェルに入る
k-mysql-sh:
	$(KUBECTL) exec -it -n $(K8S_NAMESPACE) \
	  $$($(KUBECTL) get pod -l app=mysql -n $(K8S_NAMESPACE) -o jsonpath='{.items[0].metadata.name}') \
	  -- bash

# k8s マニフェスト適用
#   make k-apply                -> k8s/ ディレクトリ配下を一括 apply
#   make k-apply FILE=k8s/mysql.yaml
k-apply:
	@if [ -z "$(FILE)" ]; then \
	  echo "Applying manifests under k8s/"; \
	  $(KUBECTL) apply -n $(K8S_NAMESPACE) -f k8s/; \
	else \
	  echo "Applying $(FILE)"; \
	  $(KUBECTL) apply -n $(K8S_NAMESPACE) -f $(FILE); \
	fi

# app ラベルで Pod を削除して再作成させる
#   make k-del-pods APP=mysql
k-del-pods:
	@if [ -z "$(APP)" ]; then \
	  echo "Usage: make k-del-pods APP=mysql"; exit 1; \
	fi
	$(KUBECTL) delete pod -l app=$(APP) -n $(K8S_NAMESPACE)

# grpc-echo Deployment の AUTH_SECRET 設定確認
k-auth:
	$(KUBECTL) get deploy grpc-echo -n $(K8S_NAMESPACE) -o yaml | grep -n "AUTH_SECRET" || true

# ---------- JWT Helper ----------
.PHONY: jwt jwt-print

# 素のトークンだけを表示したいとき（今までと同じ挙動）
jwt-print:
	cd cmd/jwt_gen && AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .

# シェルで eval して TOKEN に一発で入れたい用
jwt:
	@cd cmd/jwt_gen && \
	  token=$$(AUTH_SECRET=$(JWT_SECRET) $(GO_RUN) .); \
	  echo "export TOKEN=$$token"
