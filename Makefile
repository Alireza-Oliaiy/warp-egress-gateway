SHELL := /usr/bin/env bash

.PHONY: test syntax shellcheck compose package

test: syntax shellcheck compose

syntax:
	@bash tests/syntax.sh
	@bash tests/security-order.sh
	@bash tests/monitoring.sh

shellcheck:
	@if command -v shellcheck >/dev/null; then \
		find . -type f -name '*.sh' -not -path './release/*' -print0 | xargs -0 shellcheck; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

compose:
	@if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then \
		cp -n docker/.env.example docker/.env 2>/dev/null || true; \
		cp native/config/warp-gateway.env.example docker/generated/warp-gateway.env; \
		docker compose -f docker/compose.yaml config >/dev/null; \
		rm -f docker/generated/warp-gateway.env; \
	else \
		echo "docker compose not available; skipping compose validation"; \
	fi

package:
	@mkdir -p release
	@version=$$(cat VERSION); \
	tar --exclude='./release' --exclude='./.git' -czf "release/warp-egress-gateway-$${version}.tar.gz" .; \
	echo "release/warp-egress-gateway-$${version}.tar.gz"
