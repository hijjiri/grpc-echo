# ---------- Config ----------
GO        ?= go
GO_RUN    ?= $(GO) run
GRPCURL   ?= grpcurl
DOCKER_COMPOSE ?= docker-compose
GRPC_ADDR ?= localhost:50051
SERVICE   ?=
ARGS      ?=

# プロトファイルディレクトリ自動検出
PROTO_DIRS := $(shell find api -name '*.proto' -exec dirname {} \; | sort -u)

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
.PHONY: run-server run-client run-todo
run-server:
	$(GO_RUN) ./cmd/server

run-client:
	$(GO_RUN) ./cmd/client $(ARGS)

run-todo:
	$(GO_RUN) ./cmd/todo_client $(ARGS)

# ---------- Docker ----------
.PHONY: doc-b doc-r doc-s
doc-b:
	docker build -t grpc-echo .

doc-r:
	docker run --rm -p 50051:50051 --name grpc-echo grpc-echo

doc-s:
	-docker stop grpc-echo || true

# ---------- Docker Compose ----------
.PHONY: com-b com-db com-d com-l com-p
com-b:
	$(DOCKER_COMPOSE) up --build

com-db:
	$(DOCKER_COMPOSE) up -d db

com-d:
	$(DOCKER_COMPOSE) down

com-l:
	$(DOCKER_COMPOSE) logs -f

com-p:
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

# ---------- DB Utility ----------
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

.PHONY: run-gateway
run-gateway:
	$(GO_RUN) ./cmd/http_gateway
