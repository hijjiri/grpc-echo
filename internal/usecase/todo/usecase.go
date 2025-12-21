package todo_usecase

import (
	"context"
	"errors"
	"fmt"

	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	"go.uber.org/zap"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

var (
	// ドメイン側のエラーを再利用（alias）
	ErrEmptyTitle = domain_todo.ErrEmptyTitle
	ErrInvalidID  = domain_todo.ErrInvalidID

	// ユースケース固有なので usecase 側で定義のまま
	ErrNotFound = errors.New("todo not found")

	meter metric.Meter

	todoCreatedCounter metric.Int64Counter
	todoListCounter    metric.Int64Counter
)

// ===== 外部に公開する Usecase インターフェース =====

type Usecase interface {
	Create(ctx context.Context, title string) (*domain_todo.Todo, error)
	List(ctx context.Context) ([]*domain_todo.Todo, error)
	Delete(ctx context.Context, id int64) error
	Update(ctx context.Context, id int64, title string, done bool) (*domain_todo.Todo, error)
}

// ===== 実装 =====

type usecase struct {
	repo   domain_todo.Repository
	logger *zap.Logger
}

func New(repo domain_todo.Repository, logger *zap.Logger) Usecase {
	initMetrics()
	return &usecase{
		repo:   repo,
		logger: logger,
	}
}

func (u *usecase) log() *zap.Logger {
	return u.logger
}

func initMetrics() {
	meter = otel.Meter("github.com/hijjiri/grpc-echo/internal/usecase/todo")

	todoCreatedCounter, _ = meter.Int64Counter(
		"todo_created_total",
		metric.WithDescription("Number of todos created"),
	)

	todoListCounter, _ = meter.Int64Counter(
		"todo_list_total",
		metric.WithDescription("Number of times todos were listed"),
	)
}

func (u *usecase) Create(ctx context.Context, title string) (*domain_todo.Todo, error) {
	// ★ ドメインファクトリにタイトルのバリデーションを任せる
	t, err := domain_todo.NewTodo(title)
	if err != nil {
		// ErrEmptyTitle などのドメインエラー
		u.logger.Warn("invalid todo for create",
			zap.String("title", title),
			zap.Error(err),
		)
		return nil, err
	}

	created, err := u.repo.Create(ctx, t)
	if err != nil {
		u.logger.Error("failed to create todo in repo",
			zap.String("title", title),
			zap.Error(err),
		)
		return nil, fmt.Errorf("create todo: %w", err)
	}

	// 既存のメトリクス・ログはそのままでOK
	return created, nil
}

func (u *usecase) List(ctx context.Context) ([]*domain_todo.Todo, error) {
	list, err := u.repo.List(ctx)
	if err != nil {
		u.log().Error("failed to list todos", zap.Error(err))
		return nil, fmt.Errorf("list todo: %w", err)
	}
	u.logger.Info("todos listed (usecase)",
		zap.Int("count", len(list)),
	)

	// カウント
	todoListCounter.Add(ctx, 1,
		metric.WithAttributes(attribute.String("source", "grpc")),
	)

	u.log().Info("todos listed (usecase)", zap.Int("count", len(list)))
	return list, nil
}

func (u *usecase) Delete(ctx context.Context, id int64) error {
	// ★ ID バリデーションをドメイン側に委譲
	if err := domain_todo.ValidateID(id); err != nil {
		u.logger.Warn("invalid id for delete",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return err // = ErrInvalidID
	}

	ok, err := u.repo.Delete(ctx, id)
	if err != nil {
		u.logger.Error("failed to delete todo in repo",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return fmt.Errorf("delete todo id=%d: %w", id, err)
	}
	if !ok {
		u.logger.Warn("todo not found", zap.Int64("id", id))
		return ErrNotFound
	}

	return nil
}

func (u *usecase) Update(ctx context.Context, id int64, title string, done bool) (*domain_todo.Todo, error) {
	// ID チェック
	if err := domain_todo.ValidateID(id); err != nil {
		u.logger.Warn("invalid id for update",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return nil, err
	}

	// Aggregate を組み立てて、タイトル・完了状態を更新
	t := &domain_todo.Todo{
		ID:   id,
		Done: done,
	}
	if err := t.ChangeTitle(title); err != nil {
		u.logger.Warn("invalid title for update",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return nil, err // ErrEmptyTitle 想定
	}

	updated, err := u.repo.Update(ctx, t)
	if err != nil {
		u.logger.Error("failed to update todo in repo",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return nil, fmt.Errorf("update todo id=%d: %w", id, err)
	}

	return updated, nil
}
