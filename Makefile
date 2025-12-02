# ============================================
# Proto Code Generation (auto discovery)
# ============================================

# api/ 以下の全ての .proto を再帰的に取得
PROTO_FILES := $(shell find api -name '*.proto')

# 対応する生成ファイル群
PROTO_GO   := $(PROTO_FILES:.proto=.pb.go)
PROTO_GRPC := $(PROTO_FILES:.proto=_grpc.pb.go)

.PHONY: proto run-% build build-% tidy clean clean-bin test help \
        docker-build docker-run docker-stop docker-logs \
        evans health

# ---- Generate protobuf code ----

proto: $(PROTO_GO) $(PROTO_GRPC)

%.pb.go: %.proto
	protoc --go_out=paths=source_relative:. $<

%_grpc.pb.go: %.proto
	protoc --go-grpc_out=paths=source_relative:. $<


# ============================================
# Run Commands (cmd/<name> → run-<name>)
# ============================================

# cmd/ 以下のディレクトリ名を取得（例：server client todo_client …）
CMDS := $(shell find cmd -maxdepth 1 -mindepth 1 -type d -printf "%f\n")

# make run-server
# make run-client ARGS="-msg=hello"
run-%:
	go run ./cmd/$* $(ARGS)


# ============================================
# Build Commands (bin/<name> に出力)
# ============================================

BIN_DIR := bin

# make build → すべての cmd をビルド
build: $(CMDS:%=build-%)

# make build-server → bin/server
build-%:
	@mkdir -p $(BIN_DIR)
	go build -o $(BIN_DIR)/$* ./cmd/$*


# ============================================
# Docker (server コンテナ用)
# ============================================

IMAGE_NAME ?= grpc-echo
CONTAINER_NAME ?= grpc-echo
PORT ?= 50051

docker-build:
	docker build -t $(IMAGE_NAME) .

docker-run: docker-stop
	docker run --rm -p $(PORT):50051 --name $(CONTAINER_NAME) $(IMAGE_NAME)

docker-stop:
	- docker stop $(CONTAINER_NAME) >/dev/null 2>&1 || true

docker-logs:
	docker logs -f $(CONTAINER_NAME)


# ============================================
# gRPC Tools (evans / grpcurl / health check)
# ============================================

GRPC_HOST ?= localhost
GRPC_PORT ?= 50051
GRPC_ADDR := $(GRPC_HOST):$(GRPC_PORT)
GRPCURL ?= grpcurl
EVANS ?= evans
SERVICE ?= ""

# Evans の対話シェルを起動 (reflection 前提)
evans:
	$(EVANS) --host $(GRPC_HOST) --port $(GRPC_PORT) -r

# Health Check
# 例:
#   make health # 全体（service フィールドなし）
#   make health SERVICE=echo.v1.EchoService
#   make health SERVICE=todo.v1.TodoService
health:
	@if [ -z "$(SERVICE)" ]; then \
	  echo "$(GRPCURL) -plaintext -d '{}' $(GRPC_ADDR) grpc.health.v1.Health/Check"; \
	  $(GRPCURL) -plaintext -d '{}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	else \
	  echo "$(GRPCURL) -plaintext -d '{\"service\":\"$(SERVICE)\"}' $(GRPC_ADDR) grpc.health.v1.Health/Check"; \
	  $(GRPCURL) -plaintext -d '{"service": "$(SERVICE)"}' $(GRPC_ADDR) grpc.health.v1.Health/Check; \
	fi

# ============================================
# Utilities
# ============================================

tidy:
	go mod tidy

clean:
	rm -f $(PROTO_GO) $(PROTO_GRPC)

clean-bin:
	rm -rf $(BIN_DIR)

test:
	go test ./...


# ============================================
# Help
# ============================================

help:
	@echo ""
	@echo "Usage:"
	@echo "  make proto                     # Generate protobuf code for all .proto"
	@echo "  make run-<cmd> ARGS='...'      # Run ./cmd/<cmd>"
	@echo "  make build                     # Build all commands into ./bin/"
	@echo "  make build-<cmd>               # Build a specific cmd"
	@echo ""
	@echo "  make docker-build              # Build Docker image ($(IMAGE_NAME))"
	@echo "  make docker-run                # Run container ($(CONTAINER_NAME)) and expose $(PORT)"
	@echo "  make docker-stop               # Stop container"
	@echo "  make docker-logs               # Tail container logs"
	@echo ""
	@echo "  make evans                     # Start evans with reflection"
	@echo "  make health SERVICE=...        # Check gRPC health (grpcurl)"
	@echo ""
	@echo "  make clean                     # Remove generated pb.go files"
	@echo "  make clean-bin                 # Remove bin/ directory"
	@echo "  make tidy                      # go mod tidy"
	@echo "  make test                      # Run go test ./..."
	@echo ""
