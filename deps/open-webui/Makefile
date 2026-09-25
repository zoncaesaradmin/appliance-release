.PHONY: build test push publish release clean

build:
	bash ./scripts/build.sh

test:
	@test -s .staging/open-webui-source.tar.gz
	@test -s .staging/open-webui-source.tar.gz.sha256

push:
	bash ./scripts/push.sh

publish: push

release: build test publish

clean:
	rm -rf .staging
