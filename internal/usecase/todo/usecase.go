package todo_usecase

import (
	"context"
	"errors"

	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.uber.org/zap"
)

// ---- 公開エラー（既存テストと互換） ----

var (
	// 空タイトル
	ErrEmptyTitle = errors.New("empty title")
	// 不正なID
	ErrInvalidID = errors.New("invalid id")
	// 見つからない
	ErrNotFound = errors.New("todo not found")
)

// ---- メトリクス ----

var (
	meter metric.Meter

	todoCreatedCounter metric.Int64Counter
	todoListCounter    metric.Int64Counter
)

func init() {
	m := otel.Meter("github.com/hijjiri/grpc-echo/internal/usecase/todo")

	todoCreatedCounter, _ = m.Int64Counter(
		"todo_created_total",
		metric.WithDescription("Number of todos created"),
	)

	todoListCounter, _ = m.Int64Counter(
		"todo_list_total",
		metric.WithDescription("Number of times todos were listed"),
	)

	meter = m
}

// ---- Usecase インターフェース ----

// 既存の public API はそのまま
type Usecase interface {
	Create(ctx context.Context, title string) (*domain_todo.Todo, error)
	List(ctx context.Context) ([]*domain_todo.Todo, error)
	Delete(ctx context.Context, id int64) error
	Update(ctx context.Context, id int64, title string, done bool) (*domain_todo.Todo, error)
}

// ---- 実装 ----

// CQRS 的に、Read / Write を分けて持つ
type usecase struct {
	readRepo  domain_todo.ReadRepository
	writeRepo domain_todo.WriteRepository
	logger    *zap.Logger
}

// 既存コード・テスト用：1つの Repository を両方に使う
func New(repo domain_todo.Repository, logger *zap.Logger) Usecase {
	return &usecase{
		readRepo:  repo,
		writeRepo: repo,
		logger:    logger,
	}
}

// 将来、読み取りと書き込みで別バックエンドを使いたくなったとき用
// （今は使わなくてOK）
func NewWithRepos(
	readRepo domain_todo.ReadRepository,
	writeRepo domain_todo.WriteRepository,
	logger *zap.Logger,
) Usecase {
	return &usecase{
		readRepo:  readRepo,
		writeRepo: writeRepo,
		logger:    logger,
	}
}

// ---- Create ----

func (u *usecase) Create(ctx context.Context, title string) (*domain_todo.Todo, error) {
	if title == "" {
		u.logger.Warn("failed to create todo: empty title")
		return nil, ErrEmptyTitle
	}

	// ドメインのファクトリで不変条件をチェック
	t, err := domain_todo.NewTodo(title)
	if err != nil {
		// ドメインエラー → usecase のエラーにマッピング
		if errors.Is(err, domain_todo.ErrEmptyTitle) {
			return nil, ErrEmptyTitle
		}
		return nil, err
	}

	created, err := u.writeRepo.Create(ctx, t)
	if err != nil {
		u.logger.Error("failed to create todo in repo",
			zap.String("title", title),
			zap.Error(err),
		)
		return nil, err
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

// ---- List ----

func (u *usecase) List(ctx context.Context) ([]*domain_todo.Todo, error) {
	list, err := u.readRepo.List(ctx)
	if err != nil {
		u.logger.Error("failed to list todos",
			zap.Error(err),
		)
		return nil, err
	}

	todoListCounter.Add(ctx, 1,
		metric.WithAttributes(attribute.String("source", "grpc")),
	)

	u.logger.Info("todos listed (usecase)",
		zap.Int("count", len(list)),
	)

	return list, nil
}

// ---- Delete ----

func (u *usecase) Delete(ctx context.Context, id int64) error {
	// ID バリデーションはドメイン側のヘルパーに委譲
	if err := domain_todo.ValidateID(id); err != nil {
		u.logger.Warn("invalid id for delete",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return ErrInvalidID
	}

	deleted, err := u.writeRepo.Delete(ctx, id)
	if err != nil {
		u.logger.Error("failed to delete todo in repo",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return err
	}

	if !deleted {
		u.logger.Warn("todo not found for delete",
			zap.Int64("id", id),
		)
		return ErrNotFound
	}

	u.logger.Info("todo deleted (usecase)",
		zap.Int64("id", id),
	)

	return nil
}

// ---- Update ----

func (u *usecase) Update(ctx context.Context, id int64, title string, done bool) (*domain_todo.Todo, error) {
	if err := domain_todo.ValidateID(id); err != nil {
		u.logger.Warn("invalid id for update",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return nil, ErrInvalidID
	}

	// ドメインエンティティを組み立て
	t := &domain_todo.Todo{
		ID:    id,
		Title: title,
		Done:  done,
	}

	// タイトルのバリデーションはドメインメソッドに委譲
	if err := t.ChangeTitle(title); err != nil {
		if errors.Is(err, domain_todo.ErrEmptyTitle) {
			return nil, ErrEmptyTitle
		}
		return nil, err
	}

	updated, err := u.writeRepo.Update(ctx, t)
	if err != nil {
		u.logger.Error("failed to update todo in repo",
			zap.Int64("id", id),
			zap.String("title", title),
			zap.Bool("done", done),
			zap.Error(err),
		)
		return nil, err
	}

	u.logger.Info("todo updated (usecase)",
		zap.Int64("id", updated.ID),
		zap.String("title", updated.Title),
		zap.Bool("done", updated.Done),
	)

	return updated, nil
}
