package todo

import (
	"context"
	"testing"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestCreateTodo_Success(t *testing.T) {
	repo := NewInMemoryTodoRepository()
	s := NewTodoServer(repo)

	ctx := context.Background()
	req := &todov1.CreateTodoRequest{Title: "テストタスク"}

	res, err := s.CreateTodo(ctx, req)
	if err != nil {
		t.Fatalf("CreateTodo returned error: %v", err)
	}

	if res.GetId() == 0 {
		t.Errorf("expected non-zero id, got %d", res.GetId())
	}
	if res.GetTitle() != "テストタスク" {
		t.Errorf("expected title %q, got %q", "テストタスク", res.GetTitle())
	}
	if res.GetDone() {
		t.Errorf("expected done=false, got true")
	}
}

func TestCreateTodo_EmptyTitle(t *testing.T) {
	s := NewTodoServer(NewInMemoryTodoRepository())

	ctx := context.Background()
	req := &todov1.CreateTodoRequest{Title: ""}

	_, err := s.CreateTodo(ctx, req)
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("expected gRPC status error, got %v", err)
	}

	if st.Code() != codes.InvalidArgument {
		t.Errorf("expected code=%v, got %v", codes.InvalidArgument, st.Code())
	}
}

func TestDeleteTodo_NotFound(t *testing.T) {
	s := NewTodoServer(NewInMemoryTodoRepository())

	ctx := context.Background()
	req := &todov1.DeleteTodoRequest{Id: 999}

	_, err := s.DeleteTodo(ctx, req)
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("expected gRPC status error, got %v", err)
	}

	if st.Code() != codes.NotFound {
		t.Errorf("expected code=%v, got %v", codes.NotFound, st.Code())
	}
}

func TestDeleteTodo_Success(t *testing.T) {
	s := NewTodoServer(NewInMemoryTodoRepository())

	// まず1件作る
	ctx := context.Background()
	createRes, err := s.CreateTodo(ctx, &todov1.CreateTodoRequest{Title: "削除用タスク"})
	if err != nil {
		t.Fatalf("CreateTodo returned error: %v", err)
	}

	// そのIDでDelete
	delReq := &todov1.DeleteTodoRequest{Id: createRes.GetId()}
	delRes, err := s.DeleteTodo(ctx, delReq)
	if err != nil {
		t.Fatalf("DeleteTodo returned error: %v", err)
	}

	if !delRes.GetOk() {
		t.Errorf("expected ok=true, got false")
	}
}
