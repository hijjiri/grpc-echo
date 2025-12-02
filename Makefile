# ---- Proto auto discovery ----

# api/ 以下の全ての .proto ファイルを対象とする
PROTO_FILES := $(shell find api -name '*.proto')

# 対応する生成ファイル
PROTO_GO   := $(PROTO_FILES:.proto=.pb.go)
PROTO_GRPC := $(PROTO_FILES:.proto=_grpc.pb.go)

.PHONY: proto run-% tidy clean test help

# ---- Generate protobuf code ----

# make proto → すべての .proto から .pb.go / _grpc.pb.go を生成
proto: $(PROTO_GO) $(PROTO_GRPC)

# 1つの .proto → .pb.go
%.pb.go: %.proto
	protoc --go_out=paths=source_relative:. $<

# 1つの .proto → _grpc.pb.go
%_grpc.pb.go: %.proto
	protoc --go-grpc_out=paths=source_relative:. $<

# ---- Run commands ----

# cmd/<name> を実行する汎用ターゲット
# 例:
#   make run-server
#   make run-client ARGS="-msg=hello"
#   make run-todo_client ARGS="-mode=list"
run-%:
	go run ./cmd/$* $(ARGS)

# ---- Misc ----

tidy:
	go mod tidy

clean:
	rm -f $(PROTO_GO) $(PROTO_GRPC)

test:
	go test ./...

# ---- Help ----
help:
	@echo "Usage:"
	@echo "  make proto                     # generate protobuf code for all .proto files"
	@echo "  make run-<cmd> ARGS='...'      # run ./cmd/<cmd> with optional args"
	@echo "  make test                      # run go tests"
	@echo "  make clean                     # remove generated pb.go files"
	@echo "  make tidy                      # go mod tidy"
