.PHONY: build test login push publish release clean
build:
	bash ./scripts/build.sh
test:
	@test -f .staging/k3s/k3s && test -f .staging/helm/$(shell . ./pins.env; echo $$HELM_ARCHIVE)
login:
	@true
push:
	bash ./scripts/push.sh
publish: login
	$(MAKE) push
release:
	$(MAKE) build
	$(MAKE) publish
clean:
	rm -rf .staging
