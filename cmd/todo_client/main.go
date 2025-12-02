package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"time"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	addr := flag.String("addr", "localhost:50051", "gRPC server address")
	mode := flag.String("mode", "list", "mode: create | list | delete")
	title := flag.String("title", "", "title for create")
	id := flag.Int64("id", 0, "id for delete")
	flag.Parse()

	conn, err := grpc.Dial(
		*addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		log.Fatalf("failed to connect: %v", err)
	}
	defer conn.Close()

	client := todov1.NewTodoServiceClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	switch *mode {
	case "create":
		if *title == "" {
			log.Fatal("title is required for create")
		}
		res, err := client.CreateTodo(ctx, &todov1.CreateTodoRequest{
			Title: *title,
		})
		if err != nil {
			log.Fatalf("CreateTodo failed: %v", err)
		}
		fmt.Printf("created: id=%d title=%s done=%v\n", res.GetId(), res.GetTitle(), res.GetDone())

	case "list":
		res, err := client.ListTodos(ctx, &todov1.ListTodosRequest{})
		if err != nil {
			log.Fatalf("ListTodos failed: %v", err)
		}
		if len(res.GetTodos()) == 0 {
			fmt.Println("no todos")
			return
		}
		fmt.Println("todos:")
		for _, t := range res.GetTodos() {
			fmt.Printf("- id=%d title=%s done=%v\n", t.GetId(), t.GetTitle(), t.GetDone())
		}

	case "delete":
		if *id == 0 {
			log.Fatal("id is required for delete")
		}
		res, err := client.DeleteTodo(ctx, &todov1.DeleteTodoRequest{
			Id: *id,
		})
		if err != nil {
			log.Fatalf("DeleteTodo failed: %v", err)
		}
		fmt.Printf("delete result: ok=%v\n", res.GetOk())

	default:
		log.Fatalf("unknown mode: %s", *mode)
	}
}
