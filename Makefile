# ============================================================
# claude-in-docker — Makefile
# ============================================================

.PHONY: help build start stop restart shell verify clean logs

# 默认目标
help:
	@echo "claude-in-docker 管理命令:"
	@echo ""
	@echo "  make build     — 构建容器镜像"
	@echo "  make start     — 启动容器"
	@echo "  make stop      — 停止容器"
	@echo "  make restart   — 重启容器"
	@echo "  make shell     — 进入容器 shell"
	@echo "  make verify    — 验证网络出口"
	@echo "  make logs      — 查看容器日志"
	@echo "  make clean     — 删除容器和数据卷"
	@echo ""

# 构建镜像
build:
	podman build -t claude-in-docker-wg .

# 启动容器
start:
	./scripts/start.sh

# 停止容器
stop:
	podman stop claude-in-docker || true

# 重启容器
restart: start

# 进入容器 shell
shell:
	podman exec -it --user claude --workdir /home/claude claude-in-docker bash

# 验证网络
verify:
	podman exec claude-in-docker /usr/local/bin/claude-check

# 查看日志
logs:
	podman logs -f claude-in-docker

# 清理
clean:
	podman rm -f claude-in-docker || true
	podman volume rm claude-docker-data claude-config || true
