.PHONY: env fmt test verify local-e2e

env:
	./scripts/sentinel/check-dev-env.sh --strict

fmt:
	gofmt -w $$(find go tools -type f -name '*.go')
	forge fmt

test:
	./scripts/test-unit.sh
	./scripts/test-conformance.sh
	cd tools && go test ./...

verify:
	./scripts/sentinel/verify.sh

local-e2e:
	./scripts/full-setup.sh --test
