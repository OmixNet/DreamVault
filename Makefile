# DreamVault Makefile
# P3-8: 金标评测集 (30 case) — 跑 `make eval` 单独跑, 不绑 CI
# (Ollama 慢 + 需本机 daemon, CI 跳过)

.PHONY: help build test eval eval-ollama release

help:
	@echo "DreamVault Makefile — v0.6.7+"
	@echo ""
	@echo "  make build       - 编译 dream CLI (debug)"
	@echo "  make test        - 跑全套测试 (~550+ tests, 20-30s)"
	@echo "  make eval        - 跑金标评测集 (mock provider, ~1s, 30 case)"
	@echo "  make eval-ollama - 跑金标评测集 (Ollama 真实模型, ~5-30min, 30 case)"
	@echo "  make release     - 编译 dream CLI (release)"
	@echo ""
	@echo "P3-8 评测: 30 case (10 verified-true / 10 hallucinated / 10 contradiction pairs)"
	@echo "  写 docs/eval-YYYY-MM-DD.md, 含 P/R/F1 + 错 case 详情"

build:
	swift build

test:
	swift test

# P3-8: 金标评测集 — mock provider (快速 smoke, CI-safe)
eval:
	swift run dream eval --llm mock --report docs/eval-$(shell date +%Y-%m-%d).md

# P3-8: 金标评测集 — Ollama 真实模型 (本地 daemon, 慢, 不绑 CI)
eval-ollama:
	@echo "Warning: 需要本机跑 Ollama daemon (http://127.0.0.1:11434)"
	@echo "启动: ollama serve &  /  拉模型: ollama pull llama3.1"
	OLLAMA_BASE_URL?=http://127.0.0.1:11434 \
	OLLAMA_MODEL?=llama3.1 \
	DREAMVAULT_LLM=ollama \
	swift run dream eval --llm ollama --report docs/eval-ollama-$(shell date +%Y-%m-%d).md

release:
	swift build -c release
