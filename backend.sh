#!/bin/bash

rootDomain="${1}"
interval=43200
shift
domainWhitelist="${*}"

dir="$(pwd)"
cd $(cd "$(dirname "$0")"; pwd)

sed -i 's/# deb /deb /g' /etc/apt/sources.list
sed -i 's/\/\/.*archive.ubuntu.com/\/\/archive.ubuntu.com/g' /etc/apt/sources.list

export DEBIAN_FRONTEND=noninteractive
apt-get -y --force-yes update
apt-get -y --force-yes upgrade
apt-get -y --force-yes install curl
curl -sL https://deb.nodesource.com/setup_6.x | bash -
apt-get -y --force-yes update
apt-get -y --force-yes install nodejs openssl build-essential

su ubuntu -c 'cd ; npm install cors express'

wget https://dl.eff.org/certbot-auto -O /opt/certbot
chmod +x /opt/certbot
/opt/certbot certonly -n --agree-tos

mkdir /ssl
echo 'tmpfs /ssl tmpfs rw,size=50M 0 0' >> /etc/fstab
mount --all


cat > /rekey.sh << EndOfMessage
#!/bin/bash

function delete {
	if [ -f "\${1}" ] ; then
		for i in {1..10} ; do
			dd if=/dev/urandom of="\${1}" bs=1024 count="\$(du -k "\${1}" | cut -f1)"
		done

		rm "\${1}"
	fi
}

subdomains=''
for i in {0..31} ; do
	subdomains="\${subdomains} -d \${i}.${rootDomain}"
done

delete /ssl/keybackup.pem
openssl genrsa -out /ssl/keybackup.pem 2048

kill \$(ps ux | grep /server.js | grep -v grep | awk '{print \$2}')

/opt/certbot certonly \
	-n \
	--agree-tos \
	--register-unsafely-without-email \
	--expand \
	--standalone \
	-d \$(date +%s).${rootDomain} \
	\${subdomains}

delete /ssl/key.pem
delete /ssl/cert.pem

find /etc/letsencrypt -type f -name fullchain1.pem -exec mv {} /ssl/cert.pem \;
find /etc/letsencrypt -type f -name privkey1.pem -exec mv {} /ssl/key.pem \;

find /etc/letsencrypt -type f -exec delete {} \;
rm -rf /etc/letsencrypt

chmod -R 777 /ssl /home/ubuntu/server.js

su ubuntu -c /home/ubuntu/server.js &
/opt/certbot certonly -n --agree-tos &
sleep ${interval}
/rekey.sh &
EndOfMessage


cat > /home/ubuntu/server.js << EndOfMessage
#!/usr/bin/env node

const app				= require('express')();
const child_process		= require('child_process');
const fs				= require('fs');
const https				= require('https');

const users				= {};

const certPath			= '/ssl/cert.pem';
const keyPath			= '/ssl/key.pem';
const keyBackupPath		= '/ssl/keybackup.pem';

const domainWhitelist	= {"$(echo "${domainWhitelist}" | perl -pe 's/\s+(.)/": true, "\1/g')": true};

const hpkpHeader		= 'max-age=31536000; includeSubdomains; ' +
	[keyPath, keyBackupPath].map(path =>
		child_process.spawnSync('openssl', [
			'enc',
			'-base64'
		], {
			input: child_process.spawnSync('openssl', [
				'dgst',
				'-sha256',
				'-binary'
			], {
				input: child_process.spawnSync('openssl', [
					'rsa',
					'-in',
					path,
					'-outform',
					'der',
					'-pubout'
				]).stdout
			}).stdout
		}).stdout.toString().trim()
	).map(hash => \`pin-sha256="\${hash}"\`).join('; ')
;

const getIdFromRequest	= req =>
	\`\${req.connection.remoteAddress}-\${req.get('host')}\`
;

const validateReferrer	= (req, res) => {
	if (domainWhitelist[
		req.get('referrer').split('/')[2].split('.').slice(-2).join('.')
	]) {
		return true;
	}

	res.status(418);
	res.end('');
	return false;
};

app.use(require('cors')());

app.get('/check', (req, res) => {
	if (!validateReferrer(req, res)) {
		return;
	}

	if (users[getIdFromRequest(req)]) {
		res.status(418);
	}

	res.end('');
});

app.post('/set', (req, res) => {
	if (!validateReferrer(req, res)) {
		return;
	}

	users[getIdFromRequest(req)]	= true;
	res.set('Public-Key-Pins', hpkpHeader);
	res.end('');
});

https.createServer({
	cert: fs.readFileSync(certPath),
	key: fs.readFileSync(keyPath),
	dhparam: child_process.spawnSync('openssl', [
		'dhparam',
		/(\d+) bit/.exec(
			child_process.spawnSync('openssl', [
				'rsa',
				'-in',
				keyPath,
				'-text',
				'-noout'
			]).stdout.toString()
		)[1]
	]).stdout.toString()
}, app).listen(31337);
EndOfMessage


chmod 700 /rekey.sh

crontab -l > /tmp.cron
echo '@reboot /rekey.sh' >> /tmp.cron
crontab /tmp.cron
rm /tmp.cron

cd "${dir}"
rm backend.sh
reboot
