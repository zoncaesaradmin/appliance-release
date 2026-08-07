.PHONY: build test login push publish release clean
build:
	bash ./scripts/build.sh
test:
	@test -f .staging/host-packages.tar.zst
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
