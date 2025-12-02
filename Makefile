# ============================================
# Proto Code Generation (auto discovery)
# ============================================

# api/ 以下の全ての .proto を再帰的に取得
PROTO_FILES := $(shell find api -name '*.proto')

# 対応する生成ファイル群
PROTO_GO   := $(PROTO_FILES:.proto=.pb.go)
PROTO_GRPC := $(PROTO_FILES:.proto=_grpc.pb.go)

.PHONY: proto run-% build build-% tidy clean clean-bin test help

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
	@echo "  make clean                     # Remove generated pb.go files"
	@echo "  make clean-bin                 # Remove bin/ directory"
	@echo "  make tidy                      # go mod tidy"
	@echo "  make test                      # Run go test ./..."
	@echo ""
