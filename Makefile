all:
	rm -rf dist promise-polyfill 2> /dev/null
	mkdir dist

	wget -O dist/hpkp-supercookie.js \
		https://raw.githubusercontent.com/taylorhakes/promise-polyfill/master/promise.min.js

	cat frontend.js | uglifyjs -m >> dist/hpkp-supercookie.js

	rm -rf promise-polyfill

clean:
	rm -rf dist promise-polyfill
