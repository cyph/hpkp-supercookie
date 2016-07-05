self.HPKPSupercookie	= (function () {
	function numberToBinary (n) {
		return (new Array(32).join('0') + (n >>> 0).toString(2)).
			slice(-32).
			split('').
			map(function (n) { return parseInt(n, 10) })
		;
	}

	function binaryToNumber (bin) {
		return parseInt(bin.join(''), 2);
	}

	function newId () {
		while (true) {
			var id	= crypto.getRandomValues(new Uint32Array(1))[0];

			if (id !== 0 && id !== 4294967295) {
				return id;
			}
		}
	}

	function request (method, rootDomain, i, path) {
		return new Promise(function (resolve) {
			var xhr	= new XMLHttpRequest();

			xhr.onreadystatechange	= function () {
				if (xhr.readyState === 4) {
					resolve(xhr.status === 200);
				}
			};

			xhr.open(
				method,
				'https://' + i + '.' + rootDomain + ':31337' + path,
				true
			);

			xhr.send();
		});
	}

	function check (rootDomain) {
		var promises	= [];

		for (var i = 0 ; i < 32 ; ++i) {
			promises.push(request('GET', rootDomain, i, '/check'));
		}

		return Promise.all(promises).then(function (results) {
			return binaryToNumber(results.map(function (wasSuccessful) {
				return wasSuccessful ? 0 : 1;
			}));
		});
	}

	function set (rootDomain, id) {
		var promises	= [];
		var idBinary	= numberToBinary(id);

		for (var i = 0 ; i < 32 ; ++i) {
			if (idBinary[i] === 1) {
				promises.push(request('POST', rootDomain, i, '/set'));
			}
		}

		return Promise.all(promises).then(function (results) {
			for (var i = 0 ; i < results.length ; ++i) {
				if (!results[i]) {
					throw 'Failed to set ID.';
				}
			}

			return {id: id, isNewUser: true};
		});
	}

	return function (rootDomain) {
		return check(rootDomain).then(function (id) {
			if (id === 4294967295) {
				throw 'Failed to check ID.';
			}
			else if (id === 0) {
				return set(rootDomain, newId());
			}
			else {
				return {id: id, isNewUser: false};
			}
		});
	}
}());
