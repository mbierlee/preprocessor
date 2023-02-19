.PHONY: build
.PHONY: test
.PHONY: clean

build:
	dub build --build=release

test:
	dub test

clean:
	dub clean	

run-examples: run-cExample

run-simpleCExample:
	dub run --build=release --config=simpleCExample
