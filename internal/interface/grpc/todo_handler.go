package grpcadapter

import (
	"context"
	"errors"
	"time"

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

// 本番目線：handler 層で「処理上限」を決めて、DB詰まり等で無限にぶら下がらないようにする
const (
	defaultTodoWriteTimeout  = 3 * time.Second  // Create/Update/Delete
	defaultTodoReadTimeout   = 5 * time.Second  // List
	defaultTodoStreamTimeout = 10 * time.Second // Stream List の「取得」側
)

// --- Create ---
func (h *TodoHandler) CreateTodo(ctx context.Context, req *todov1.CreateTodoRequest) (*todov1.Todo, error) {
	ctx, cancel := context.WithTimeout(ctx, defaultTodoWriteTimeout)
	defer cancel()

	t, err := h.uc.Create(ctx, req.GetTitle())
	if err != nil {
		return nil, toGRPCError(err)
	}
	return toProtoTodo(t), nil
}

// --- List ---
func (h *TodoHandler) ListTodos(ctx context.Context, req *todov1.ListTodosRequest) (*todov1.ListTodosResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, defaultTodoReadTimeout)
	defer cancel()

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
	ctx, cancel := context.WithTimeout(ctx, defaultTodoWriteTimeout)
	defer cancel()

	if err := h.uc.Delete(ctx, req.GetId()); err != nil {
		return nil, toGRPCError(err)
	}
	// proto 側にフィールドが無いので、空メッセージだけ返す
	return &todov1.DeleteTodoResponse{}, nil
}

func (h *TodoHandler) UpdateTodo(ctx context.Context, req *todov1.UpdateTodoRequest) (*todov1.Todo, error) {
	ctx, cancel := context.WithTimeout(ctx, defaultTodoWriteTimeout)
	defer cancel()

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
	// context 系（timeout/cancel）は Internal にしない（本番目線で重要）
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "request timeout")
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "request canceled")
	}

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
	// stream の ctx はクライアント切断を反映するので基本はこれを使う
	baseCtx := stream.Context()

	// 「取得」部分だけは timeout を付与して、DB詰まりで無限に待たないようにする
	listCtx, cancel := context.WithTimeout(baseCtx, defaultTodoStreamTimeout)
	defer cancel()

	todos, err := h.uc.List(listCtx)
	if err != nil {
		return toGRPCError(err)
	}

	for _, t := range todos {
		// 送信前に ctx を尊重（クライアント切断を早く検知）
		select {
		case <-baseCtx.Done():
			return toGRPCError(baseCtx.Err())
		default:
		}

		resp := &todov1.Todo{
			Id:    t.ID,
			Title: t.Title,
			Done:  t.Done,
		}

		if err := stream.Send(resp); err != nil {
			// transport error（切断等）
			return err
		}
	}

	return nil
}
