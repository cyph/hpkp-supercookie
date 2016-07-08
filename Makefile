all:
	rm -rf dist 2> /dev/null
	mkdir dist

	wget -O dist/hpkp-supercookie.js \
		https://raw.githubusercontent.com/taylorhakes/promise-polyfill/master/promise.min.js

	cat frontend.js | uglifyjs -m >> dist/hpkp-supercookie.js

clean:
	rm -rf dist
