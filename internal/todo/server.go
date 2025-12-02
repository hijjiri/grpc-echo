// internal/todo/server.go
package todo

import (
	"context"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type TodoServer struct {
	todov1.UnimplementedTodoServiceServer

	repo TodoRepository
}

func NewTodoServer(repo TodoRepository) *TodoServer {
	return &TodoServer{
		repo: repo,
	}
}

func (s *TodoServer) CreateTodo(ctx context.Context, req *todov1.CreateTodoRequest) (*todov1.Todo, error) {
	title := req.GetTitle()
	if title == "" {
		return nil, status.Error(codes.InvalidArgument, "title must not be empty")
	}

	t, err := s.repo.Create(ctx, title)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to create todo")
	}
	return t, nil
}

func (s *TodoServer) ListTodos(ctx context.Context, req *todov1.ListTodosRequest) (*todov1.ListTodosResponse, error) {
	todos, err := s.repo.List(ctx)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to list todos")
	}
	return &todov1.ListTodosResponse{
		Todos: todos,
	}, nil
}

func (s *TodoServer) DeleteTodo(ctx context.Context, req *todov1.DeleteTodoRequest) (*todov1.DeleteTodoResponse, error) {
	id := req.GetId()
	if id == 0 {
		return nil, status.Error(codes.InvalidArgument, "id must be non-zero")
	}

	ok, err := s.repo.Delete(ctx, id)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to delete todo")
	}
	if !ok {
		return nil, status.Error(codes.NotFound, "todo not found")
	}

	return &todov1.DeleteTodoResponse{
		Ok: true,
	}, nil
}
