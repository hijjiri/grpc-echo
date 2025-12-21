package todo_usecase

import (
	"context"
	"errors"
	"fmt"

	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.uber.org/zap"
)

// --------- OpenTelemetry メトリクス ---------

var (
	meter = otel.Meter("github.com/hijjiri/grpc-echo/internal/usecase/todo")

	todoCreatedCounter metric.Int64Counter
	todoListCounter    metric.Int64Counter
)

func init() {
	var err error

	todoCreatedCounter, err = meter.Int64Counter(
		"todo_created_total",
		metric.WithDescription("Number of todos created"),
	)
	if err != nil {
		// ロガーがないので、ここでは黙っておく
	}

	todoListCounter, err = meter.Int64Counter(
		"todo_list_total",
		metric.WithDescription("Number of times todos were listed"),
	)
	if err != nil {
	}
}

// --------- TxManager インターフェース ---------

// TxManager は「この処理をトランザクション内で実行する」ための抽象。
type TxManager interface {
	WithinTx(ctx context.Context, fn func(ctx context.Context) error) error
}

// --------- 公開インターフェース ---------

type Usecase interface {
	Create(ctx context.Context, title string) (*domain_todo.Todo, error)
	List(ctx context.Context) ([]*domain_todo.Todo, error)
	Delete(ctx context.Context, id int64) error
	Update(ctx context.Context, id int64, title string, done bool) (*domain_todo.Todo, error)
}

// usecase は Read/Write 両方の Repository を持ち、TxManager と logger を注入する。
type usecase struct {
	readRepo  domain_todo.ReadRepository
	writeRepo domain_todo.WriteRepository
	tx        TxManager
	logger    *zap.Logger
}

// nopTxManager は「Tx を貼らずにそのまま実行するだけ」の実装。
// テストや Tx 不要な場合のデフォルトとして使う。
type nopTxManager struct{}

func (nopTxManager) WithinTx(ctx context.Context, fn func(ctx context.Context) error) error {
	return fn(ctx)
}

// New は Todo Usecase を構築する。
// TxManager が nil の場合は nopTxManager を使う。
func New(repo domain_todo.Repository, tx TxManager, logger *zap.Logger) Usecase {
	if logger == nil {
		logger = zap.NewNop()
	}
	if tx == nil {
		tx = nopTxManager{}
	}

	return &usecase{
		readRepo:  repo,
		writeRepo: repo,
		tx:        tx,
		logger:    logger,
	}
}

// --------- usecase レベルのエラー（ドメインエラーのラップ） ---------

var (
	ErrEmptyTitle = domain_todo.ErrEmptyTitle
	ErrInvalidID  = domain_todo.ErrInvalidID
	ErrNotFound   = errors.New("todo not found")
)

// --------- 実装 ---------

func (u *usecase) Create(ctx context.Context, title string) (*domain_todo.Todo, error) {
	// ドメインのコンストラクタでバリデーション
	t, err := domain_todo.NewTodo(title)
	if err != nil {
		// ErrEmptyTitle のようなドメインエラーを usecase エラーにマッピングする場合はここで。
		if errors.Is(err, domain_todo.ErrEmptyTitle) {
			return nil, ErrEmptyTitle
		}
		return nil, err
	}

	var created *domain_todo.Todo

	// 書き込み系なので Tx を貼る
	err = u.tx.WithinTx(ctx, func(txCtx context.Context) error {
		var repoErr error
		created, repoErr = u.writeRepo.Create(txCtx, t)
		return repoErr
	})
	if err != nil {
		u.logger.Error("failed to create todo",
			zap.String("title", title),
			zap.Error(err),
		)
		return nil, fmt.Errorf("create todo: %w", err)
	}

	// メトリクス
	todoCreatedCounter.Add(ctx, 1,
		metric.WithAttributes(attribute.String("source", "grpc")),
	)

	u.logger.Info("todo created (usecase)",
		zap.Int64("id", created.ID),
		zap.String("title", created.Title),
	)

	return created, nil
}

func (u *usecase) List(ctx context.Context) ([]*domain_todo.Todo, error) {
	list, err := u.readRepo.List(ctx)
	if err != nil {
		u.logger.Error("failed to list todos", zap.Error(err))
		return nil, fmt.Errorf("list todos: %w", err)
	}

	// メトリクス
	todoListCounter.Add(ctx, 1,
		metric.WithAttributes(attribute.String("source", "grpc")),
	)

	u.logger.Info("todos listed (usecase)",
		zap.Int("count", len(list)),
	)

	return list, nil
}

func (u *usecase) Delete(ctx context.Context, id int64) error {
	if err := domain_todo.ValidateID(id); err != nil {
		return ErrInvalidID
	}

	var deleted bool

	// 書き込み系なので Tx を貼る
	err := u.tx.WithinTx(ctx, func(txCtx context.Context) error {
		var repoErr error
		deleted, repoErr = u.writeRepo.Delete(txCtx, id)
		return repoErr
	})
	if err != nil {
		u.logger.Error("failed to delete todo",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return fmt.Errorf("delete todo: %w", err)
	}

	if !deleted {
		return ErrNotFound
	}

	u.logger.Info("todo deleted (usecase)", zap.Int64("id", id))
	return nil
}

func (u *usecase) Update(ctx context.Context, id int64, title string, done bool) (*domain_todo.Todo, error) {
	if err := domain_todo.ValidateID(id); err != nil {
		return nil, ErrInvalidID
	}

	t := &domain_todo.Todo{
		ID:   id,
		Done: done,
	}

	if err := t.ChangeTitle(title); err != nil {
		if errors.Is(err, domain_todo.ErrEmptyTitle) {
			return nil, ErrEmptyTitle
		}
		return nil, err
	}

	var updated *domain_todo.Todo

	// 書き込み系なので Tx を貼る
	err := u.tx.WithinTx(ctx, func(txCtx context.Context) error {
		var repoErr error
		updated, repoErr = u.writeRepo.Update(txCtx, t)
		return repoErr
	})
	if err != nil {
		u.logger.Error("failed to update todo",
			zap.Int64("id", id),
			zap.String("title", title),
			zap.Bool("done", done),
			zap.Error(err),
		)
		return nil, fmt.Errorf("update todo: %w", err)
	}

	u.logger.Info("todo updated (usecase)",
		zap.Int64("id", updated.ID),
		zap.String("title", updated.Title),
		zap.Bool("done", updated.Done),
	)

	return updated, nil
}
