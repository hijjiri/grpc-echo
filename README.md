いい区切りポイントなので、一回いまの状態を棚卸ししておきましょう 🙆‍♂️

---

## 1. 現在のプロジェクト環境の評価

### ✅ 開発環境・インフラ

* OS: WSL2 上の Ubuntu
* 言語: Go 1.24.10
* DB: MySQL（Docker Compose で起動、初期化 SQL あり）
* コンテナ:

  * `grpc-echo-server`（アプリ）
  * `grpc-mysql`（DB）
* ローカル実行も Docker 実行も両対応
  → **「全部 Docker」も「ローカル直叩き」も選べる柔軟な構成**

### ✅ アプリ構成 & アーキテクチャ

* gRPC サーバ（Echo + Todo + Health）
* proto → `api/*/v1` に配置、Makefile で `protoc` 自動生成
* Clean Architecture ベースの分割：

  * `internal/domain/todo`
  * `internal/usecase/todo`
  * `internal/infrastructure/mysql`
  * `internal/interface/grpc`
* Todo の Repository はメモリ版 → MySQL 版へ差し替え済み
* クライアント:

  * `cmd/client`（Echo 用）
  * `cmd/todo_client`（Todo 用 CLI）

➡ **「小さくてもちゃんとレイヤが分かれた業務アプリ」になっている。**

### ✅ 開発者体験（DX）

* Makefile で主な操作をコマンド化：

  * `make proto`, `make run-server`, `make run-todo`, `make com-b` など
* README にセットアップ～実行手順を整理済み
* `go test ./...` で一括テスト

➡ **復職後のリハビリという観点でもかなり快適な環境。**

### ✅ テスト・品質

* `internal/usecase/todo` にユニットテスト

  * mock repository によるビジネスロジックの検証
* `go test ./...` でクリーンに通る状態
* ハンドリング済みエラー：

  * `ErrEmptyTitle`
  * `ErrInvalidID`
  * `ErrNotFound`

➡ **「Usecase のテストが書けている」時点で、業務でも十分戦えるレベル。**

### ✅ 観測性（Observability）

* ログ:

  * `zap.NewProduction` による JSON 構造化ログ
  * 起動ログ、DB接続ログ、Repository ログ、Usecase ログ
  * gRPC Interceptor でメソッド名＋処理時間＋エラーを一元ログ
* Health:

  * gRPC Health Checking 実装
  * `grpcurl` + Makefile でヘルスチェック可能

➡ **ログまわりはすでに“実運用仕様”。あとはトレース / メトリクスを足せる状態。**

---

## 2. いまの環境の「強み」と「まだ伸ばせるポイント」

### 強み

* 小さくてもクリーンアーキをちゃんと踏んでいる
* Docker / Compose でローカル環境が再現可能
* Usecase テスト + エラーデザイン + ログ設計まで意識できている
* gRPC & MySQL & Container という実務ラインの技術が一通り触れている

### まだ伸ばせるポイント（あえて言うなら）

* トレーシング（OpenTelemetry）、メトリクス（Prometheus）が未導入
* CI/CD（GitHub Actions）での自動テスト・Lint がまだ
* 認証・認可（ユーザー概念）がない
* K8s デプロイは未体験
* Echo サービスはまだ “サンプル” レイヤに留まっている

---

## 3. 今後の発展案（レベル別ロードマップ）

### 🔹 Step 1: 「このプロジェクトを完成度高いサンプル」にする

**ゴール:**
「後から見返しても、これを雛形にすれば仕事を始められる」レベル。

やると良さそうなこと：

1. **Error設計の仕上げ**

   * `toGRPCError` を現在の形に確定
   * Interceptor 側で `NotFound` を Warn、その他を Error ログに分ける
2. **Usecase テストの充実**

   * Update / Delete の異常系（InvalidID / NotFound）のテーブルドリブンテスト
   * coverage をざっくりでいいので 80% 近くまで上げてみる
3. **README の“設計部分”を強化**

   * レイヤ構成図（domain / usecase / infra / interface）
   * エラーフロー（Repository → Usecase → gRPC status）

---

### 🔹 Step 2: 実運用寄りの機能追加

**ゴール:**
「小さいけど本番に出せるサービス」クラスにする。

おすすめ順：

1. **OpenTelemetry Tracing**

   * gRPC に interceptor 追加
   * Jaeger or Tempo に飛ばして、リクエストの流れを可視化
2. **Prometheus Metrics**

   * gRPC のメトリクスエクスポート（リクエスト数 / レイテンシ / ステータス）
3. **Graceful Shutdown**

   * OS シグナルを拾って、gRPC / DB を安全に閉じる
4. **GitHub Actions で CI**

   * `go test ./...`
   * `go vet`, `golangci-lint` あたりを流す

---

### 🔹 Step 3: 設計・ドメイン寄りの発展

**ゴール:**
「設計が評価されるバックエンドエンジニア」ライン。

やってみると面白いもの：

1. **Todo にユーザー概念・認証を追加**

   * `User` エンティティ
   * JWT 認証
   * context に userID 注入
2. **CQRS っぽい分離**

   * 書き込み: TodoUsecase（今のまま）
   * 読み取り: List 専用の ReadModel（JOIN や集計用）
3. **DDD 風のモデリングの練習**

   * ValueObject（Title, TodoID など）
   * DomainService が必要なケースを考えてみる
4. **Echo サービスも CA 構成に寄せる**

   * `echo` ドメイン / usecase / adapter を追加して「複数ドメイン共存」を体験

---

### 🔹 Step 4: 実務系 “+α” の発展

余裕が出てきたら、こういう方向もあり：

* **gRPC-Gateway で REST API を自動生成**
  → 同じ proto から REST / gRPC 両対応
* **Kubernetes にデプロイ**

  * Deployment / Service / ConfigMap / Secret
  * readiness / liveness probe に Health API を使う
* **フロントエンド（小さな Vue/React）から gRPC-Gateway 経由で Todo を叩く**
  → フルスタックで一連の流れを確認できる
