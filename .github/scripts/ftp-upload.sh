#!/usr/bin/env bash
# Uploads public/ to the hosting account. Shared hosts drop FTP connections
# now and then, so every transfer is retried instead of failing the deploy.
#
# Needs FTP_SERVER, FTP_USERNAME and FTP_PASSWORD. FTP_DIR is the site's
# folder as the FTP login sees it (default public_html/); FTP_PROTOCOL is
# ftps (default) or ftp.
set -euo pipefail

dir="${FTP_DIR:-public_html/}"
tls=true
[ "${FTP_PROTOCOL:-ftps}" = ftp ] && tls=false

export LFTP_PASSWORD="$FTP_PASSWORD"
lftp -c "
set cmd:fail-exit yes
set ftp:ssl-allow $tls
set ftp:ssl-force $tls
set ftp:ssl-protect-data $tls
set ftp:passive-mode yes
# Shared hosts often serve FTPS with the server's own certificate, not one
# for the address used here; the connection is still encrypted.
set ssl:verify-certificate no
set net:timeout 30
set net:max-retries 10
set net:reconnect-interval-base 5
set net:reconnect-interval-multiplier 2
set net:reconnect-interval-max 60
open --env-password -u \"$FTP_USERNAME\" \"$FTP_SERVER\"
mirror --reverse --no-perms --verbose=1 --parallel=2 public/ \"$dir\"
"
echo "Uploaded to $dir"
