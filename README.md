# HPKP Supercookie

1. Pick a domain to use for the supercookie server, e.g. `cyph.wang`.

2. Point `*.cyph.wang` at a server running Ubuntu 14.04.

3. Run `backend.sh ${domainWhitelist}` on the server, with `domainWhitelist` being a
whitespace-separated list of root domains approved to access this supercookie server.

4. Include `hpkp-supercookie.js` in your web frontend code.

5. `const userData /* {id: number; isNewUser: boolean;} */ = await HPKPSupercookie('cyph.wang');`

6. Track individual users between different sites and in incognito mode.

7. ???

8. PROFIT!
