.PHONY: build test login push publish release clean

build:
	bash ./scripts/build.sh

test:
	@test -f .staging/local-ref && echo "ok: $$(cat .staging/local-ref)" || (echo "run make build first" >&2; exit 1)

login:
	@bash -c 'source ../../scripts/deps-common.sh && deps_oci_login'

push:
	bash ./scripts/push.sh

publish: login
	$(MAKE) push

release:
	$(MAKE) build
	$(MAKE) publish

clean:
	rm -rf .staging
