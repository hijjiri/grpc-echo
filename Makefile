PROTO_ECHO_DIR=api/echo/v1
PROTO_TODO_DIR=api/todo/v1

.PHONY: proto run-server run-client run-todo-client tidy clean

proto:
	protoc --go_out=paths=source_relative:. --go-grpc_out=paths=source_relative:. $(PROTO_ECHO_DIR)/echo.proto
	protoc --go_out=paths=source_relative:. --go-grpc_out=paths=source_relative:. $(PROTO_TODO_DIR)/todo.proto

run-server:
	go run ./cmd/server

run-client:
	go run ./cmd/client -msg="hello"

run-todo-client:
	go run ./cmd/todo_client -mode=list

tidy:
	go mod tidy

clean:
	rm -f $(PROTO_ECHO_DIR)/*.pb.go
	rm -f $(PROTO_TODO_DIR)/*.pb.go
