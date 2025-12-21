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
	if userID, ok := UserIDFromContext(ctx); ok {
		// ここで userID に応じたフィルタや認可を付けることもできる
		_ = userID
	}

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

func (h *TodoHandler) UpdateTodo(ctx context.Context, req *todov1.UpdateTodoRequest) (*todov1.Todo, error) {
	t, err := h.uc.Update(ctx, req.GetId(), req.GetTitle(), req.GetDone())
	if err != nil {
		return nil, toGRPCError(err)
	}
	return toProtoTodo(t), nil
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
	switch {
	case errors.Is(err, todo_usecase.ErrEmptyTitle):
		return status.Error(codes.InvalidArgument, "title is required")

	case errors.Is(err, todo_usecase.ErrInvalidID):
		return status.Error(codes.InvalidArgument, "invalid id")

	case errors.Is(err, todo_usecase.ErrNotFound):
		return status.Error(codes.NotFound, "todo not found")

	default:
		// Internal詳細はログ側にだけ残す（handler や interceptor で）
		return status.Error(codes.Internal, "internal error")
	}
}

// 既存の ListTodos と同じように usecase を呼んで、
// 返ってきた slice を 1 件ずつ stream.Send するだけ
func (h *TodoHandler) ListTodosStream(
	req *todov1.ListTodosRequest,
	stream todov1.TodoService_ListTodosStreamServer,
) error {
	ctx := stream.Context()

	// 既存の ListTodos と同じ usecase を利用
	todos, err := h.uc.List(ctx)
	if err != nil {
		// 既にあるロガーを使っている場合は、そちらに合わせてください
		// h.logger.Error("failed to list todos (stream)", zap.Error(err))
		return err
	}

	for _, t := range todos {
		resp := &todov1.Todo{
			Id:    t.ID,
			Title: t.Title,
			Done:  t.Done,
			// created_at / updated_at を proto に出しているならここでセット
		}

		if err := stream.Send(resp); err != nil {
			// クライアント側が切断した場合など
			// h.logger.Warn("failed to send todo (stream)", zap.Error(err))
			return err
		}
	}

	return nil
}
