package main

import (
	"context"
	"flag"
	"log"
	"time"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	addr := flag.String("addr", "localhost:50051", "gRPC server address")
	msg := flag.String("msg", "hello", "message to send")
	flag.Parse()

	// サーバーへ接続
	conn, err := grpc.Dial(
		*addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		log.Fatalf("failed to connect: %v", err)
	}
	defer conn.Close()

	client := echov1.NewEchoServiceClient(conn)

	// タイムアウト付きコンテキスト
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	// Echo RPC 呼び出し
	resp, err := client.Echo(ctx, &echov1.EchoRequest{Message: *msg})
	if err != nil {
		log.Fatalf("failed to call Echo: %v", err)
	}

	log.Printf("response: %s", resp.GetMessage())
}
