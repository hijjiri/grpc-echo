package todo

import (
	"errors"
	"time"
)

// Todo は Todo 集約のルートエンティティ。
type Todo struct {
	ID        int64
	Title     string
	Done      bool
	CreatedAt time.Time
	UpdatedAt time.Time
}

// ---- ドメインエラー（sentinel error） ----

var (
	// タイトルが空のときに使う共通エラー。
	ErrEmptyTitle = errors.New("todo title must not be empty")

	// ID が 0 以下など不正なときに使う共通エラー。
	ErrInvalidID = errors.New("todo id must be positive")
)

// ---- ファクトリ / バリデーション ----

// NewTodo は「新規作成用」のコンストラクタ。
// 不変条件（タイトルが空でないこと）をここでチェックする。
func NewTodo(title string) (*Todo, error) {
	if title == "" {
		return nil, ErrEmptyTitle
	}

	return &Todo{
		Title: title,
		Done:  false,
	}, nil
}

// ChangeTitle はタイトル変更用メソッド。
// 「空文字禁止」のルールをドメイン側に閉じ込める。
func (t *Todo) ChangeTitle(title string) error {
	if title == "" {
		return ErrEmptyTitle
	}
	t.Title = title
	return nil
}

// ValidateID は ID まわりの共通バリデーション。
func ValidateID(id int64) error {
	if id <= 0 {
		return ErrInvalidID
	}
	return nil
}
