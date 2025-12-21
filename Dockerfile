FROM golang:1.24 AS builder

WORKDIR /app

# Go Modules を利用したキャッシュ効率化
COPY go.mod go.sum ./
RUN go mod download

# ソースをコピー
COPY . .

# cmd/server をビルド
RUN CGO_ENABLED=0 go build -o server ./cmd/server
RUN CGO_ENABLED=0 go build -o http_gateway ./cmd/http_gateway

# ============================================
# 2. Runtime Stage
# ============================================
FROM gcr.io/distroless/base-debian12 AS final

WORKDIR /app
COPY --from=builder /app/server .
COPY --from=builder /app/http_gateway .

EXPOSE 50051

ENTRYPOINT ["./server"]
