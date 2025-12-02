動作確認
Echo API
grpcurl -plaintext -d '{"message":"hello"}' \
  localhost:50051 echo.v1.EchoService/Echo

Todo API
新規追加
go run ./cmd/todo_client -mode=create -title="sample todo"

一覧取得
go run ./cmd/todo_client -mode=list
