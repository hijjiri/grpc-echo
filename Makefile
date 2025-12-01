PROTO_DIR=api/echo/v1

.PHONY: proto run-server run-client tidy clean

proto:
	protoc --go_out=paths=source_relative:. --go-grpc_out=paths=source_relative:. $(PROTO_DIR)/echo.proto

run-server:
	go run ./cmd/server

run-client:
	go run ./cmd/client -msg="hello"

tidy:
	go mod tidy

clean:
	rm -f $(PROTO_DIR)/*.pb.go
