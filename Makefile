.PHONY: run format

bin/tilikuv: src/**/*.v
	v -keepc -showcc -o bin/tilikuv src/app.v
#	v -keepc -showcc -o bin/cli src/cli.v
bin:
	mkdir bin
run: bin/tilikuv
	./bin/tilikuv
format:
	v fmt -w src
push:
	pijul push --all
test:
	v test .

