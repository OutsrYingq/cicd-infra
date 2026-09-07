# syntax=docker/dockerfile:1
# Node.js 服务构建模板（ADR-9：test -> build -> 运行镜像，测试不过构建不过）
# 使用：拷贝到业务仓库根目录，按需调整 NODE_VERSION 与启动入口
ARG NODE_VERSION=22-alpine

FROM node:${NODE_VERSION} AS test
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm test --if-present

FROM test AS build
RUN npm run build --if-present
# 移除 devDependencies，减小运行镜像
RUN npm prune --omit=dev

FROM node:${NODE_VERSION}
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build --chown=node:node /app /app
USER node
# 与 chart 的 service.port 保持一致
EXPOSE 8080
# 按项目入口调整（dist/main.js / dist/index.js ...）
CMD ["node", "dist/index.js"]
