# grpc-echo

Go のリハビリ用に作成した gRPC サーバー。

- EchoService: 送られた文字列をそのまま返す
- TodoService: メモリ内に Todo を保持する簡易 API

## 動作環境

- Go 1.24.10 以上
- protoc
- protoc-gen-go
- protoc-gen-go-grpc

## セットアップ

```bash
git clone https://github.com/hijjiri/grpc-echo.git
cd grpc-echo

# 依存関係の取得
go mod tidy

# protobuf からコード生成
make proto
