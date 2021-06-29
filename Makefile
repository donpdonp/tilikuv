.PHONY: run build format

build: bin
	v -keepc -showcc -o bin/app src/app.v
#	v -keepc -showcc -o bin/cli src/cli.v
bin:
	mkdir bin
run: build
	./bin/app
format:
	v fmt -w src
push:
	pijul push --all
test:
	v test .

