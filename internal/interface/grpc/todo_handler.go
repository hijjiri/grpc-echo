package grpcadapter

import (
	"context"
	"errors"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	todo_usecase "github.com/hijjiri/grpc-echo/internal/usecase/todo"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type TodoHandler struct {
	todov1.UnimplementedTodoServiceServer
	uc todo_usecase.Usecase
}

func NewTodoHandler(uc todo_usecase.Usecase) *TodoHandler {
	return &TodoHandler{uc: uc}
}

// --- Create ---
func (h *TodoHandler) CreateTodo(ctx context.Context, req *todov1.CreateTodoRequest) (*todov1.Todo, error) {
	t, err := h.uc.Create(ctx, req.GetTitle())
	if err != nil {
		return nil, toGRPCError(err)
	}
	return toProtoTodo(t), nil
}

// --- List ---
func (h *TodoHandler) ListTodos(ctx context.Context, req *todov1.ListTodosRequest) (*todov1.ListTodosResponse, error) {
	list, err := h.uc.List(ctx)
	if err != nil {
		return nil, toGRPCError(err)
	}

	resp := &todov1.ListTodosResponse{}
	for _, t := range list {
		resp.Todos = append(resp.Todos, toProtoTodo(t))
	}
	return resp, nil
}

// --- Delete ---
func (h *TodoHandler) DeleteTodo(ctx context.Context, req *todov1.DeleteTodoRequest) (*todov1.DeleteTodoResponse, error) {
	if err := h.uc.Delete(ctx, req.GetId()); err != nil {
		return nil, toGRPCError(err)
	}
	// proto 側にフィールドが無いので、空メッセージだけ返す
	return &todov1.DeleteTodoResponse{}, nil
}

// --- converter (domain -> proto) ---
func toProtoTodo(t *domain_todo.Todo) *todov1.Todo {
	return &todov1.Todo{
		Id:    t.ID,
		Title: t.Title,
		Done:  t.Done,
	}
}

// --- error mapper ---
func toGRPCError(err error) error {
	// Usecase 側でエラーをエクスポートしている場合はここで分岐
	switch {
	case errors.Is(err, todo_usecase.ErrEmptyTitle):
		return status.Error(codes.InvalidArgument, "title is required")
	case errors.Is(err, todo_usecase.ErrInvalidID):
		return status.Error(codes.InvalidArgument, "invalid id")
	case errors.Is(err, todo_usecase.ErrNotFound):
		return status.Error(codes.NotFound, "todo not found")
	default:
		return status.Error(codes.Internal, err.Error())
	}
}
