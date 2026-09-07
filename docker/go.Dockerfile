# syntax=docker/dockerfile:1
# Go 服务构建模板（ADR-9：test -> build -> 运行镜像，测试不过编译不过）
# 使用：拷贝到业务仓库根目录，按需调整 GO_VERSION 与 main 包路径
ARG GO_VERSION=1.24

FROM golang:${GO_VERSION}-alpine AS test
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go test ./...

FROM test AS build
# main 包在根目录；子目录服务改成 ./cmd/xxx
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/app .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata \
    && adduser -D -u 10001 app
WORKDIR /app
COPY --from=build /out/app /usr/local/bin/app
USER app
# 与 chart 的 service.port 保持一致
EXPOSE 8080
ENTRYPOINT ["app"]
