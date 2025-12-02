# ---- Proto auto discovery ----

# api/ 以下の全ての .proto ファイルを対象にする
PROTO_FILES := $(shell find api -name '*.proto')

# 対応する生成ファイル群
PROTO_GO   := $(PROTO_FILES:.proto=.pb.go)
PROTO_GRPC := $(PROTO_FILES:.proto=_grpc.pb.go)

.PHONY: proto run-server run-client run-todo-client run-% tidy clean test

# すべての proto から pb.go / _grpc.pb.go を生成
proto: $(PROTO_GO) $(PROTO_GRPC)

# 1つの .proto から .pb.go を生成する規則
%.pb.go: %.proto
	protoc --go_out=paths=source_relative:. $<

# 1つの .proto から _grpc.pb.go を生成する規則
%_grpc.pb.go: %.proto
	protoc --go-grpc_out=paths=source_relative:. $<

# ---- Run targets ----

run-server:
	go run ./cmd/server

run-client:
	go run ./cmd/client -msg="hello"

run-todo-client:
	go run ./cmd/todo_client -mode=list

# パターンで任意の cmd/* を実行することもできる
#   例: make run-todo_client でも OK
run-%:
	go run ./cmd/$*

# ---- Misc ----

tidy:
	go mod tidy

clean:
	rm -f $(PROTO_GO) $(PROTO_GRPC)

test:
	go test ./...
