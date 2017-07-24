#!/bin/bash

# Disable Strict Host checking for non interactive git clones

mkdir -p -m 0700 /root/.ssh
echo -e "Host *\n\tStrictHostKeyChecking no\n" >> /root/.ssh/config

#disable ipv6 since Docker Cloud doesn't support it yet and alpine nslookups randomly resolve with ipv6 addresses.
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "ipv6" >> /etc/modules

# FIX: Slow DNS issues on docker v1.11.x (Weird issues like these: https://github.com/moby/moby/issues/22185)
# force dns lookups to happen over TCP and add google dns and OVH dns as backup nameservers
# (OVH dns is only accessible if container is run within the OVH infrastructure)
sed -n '1p' /etc/resolv.conf | tee /etc/resolv.conf
echo "nameserver 127.0.0.11" >> /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf
echo "nameserver 213.186.33.99" >> /etc/resolv.conf
echo "options use-vc ndots:0" >> /etc/resolv.conf

if [[ "$GIT_USE_SSH" == "1" ]] ; then
  echo -e "Host *\n\tUser ${GIT_USERNAME}\n\n" >> /root/.ssh/config
fi

if [ ! -z "$SSH_KEY" ]; then
 echo $SSH_KEY > /root/.ssh/id_rsa.base64
 base64 -d /root/.ssh/id_rsa.base64 > /root/.ssh/id_rsa
 chmod 600 /root/.ssh/id_rsa
fi

# Set custom webroot
if [ ! -z "$WEBROOT" ]; then
 sed -i "s#root /var/www/html;#root ${WEBROOT};#g" /etc/nginx/sites-available/default.conf
else
 webroot=/var/www/html
fi

# Setup git variables
if [ ! -z "$GIT_EMAIL" ]; then
 git config --global user.email "$GIT_EMAIL"
fi
if [ ! -z "$GIT_NAME" ]; then
 git config --global user.name "$GIT_NAME"
 git config --global push.default simple
fi

# Dont pull code down if the .git folder exists
if [ ! -d "/var/www/html/.git" ]; then
 # Pull down code from git for our site!
 if [ ! -z "$GIT_REPO" ]; then
   # Remove the test index file
   rm -Rf /var/www/html/*
   if [ ! -z "$GIT_BRANCH" ]; then
     if [ -z "$GIT_USERNAME" ] && [ -z "$GIT_PERSONAL_TOKEN" ]; then
       git clone -b $GIT_BRANCH $GIT_REPO /var/www/html/
     else
       git clone -b ${GIT_BRANCH} https://${GIT_USERNAME}:${GIT_PERSONAL_TOKEN}@${GIT_REPO} /var/www/html
     fi
   else
     if [ -z "$GIT_USERNAME" ] && [ -z "$GIT_PERSONAL_TOKEN" ]; then
       git clone $GIT_REPO /var/www/html/
     else
       git clone https://${GIT_USERNAME}:${GIT_PERSONAL_TOKEN}@${GIT_REPO} /var/www/html
     fi
   fi
   chown -Rf nginx.nginx /var/www/html
 fi
else
 if [ ! -z "$GIT_REPULL" ]; then
   git -C /var/www/html rm -r --quiet --cached /var/www/html
   git -C /var/www/html fetch --all -p
   git -C /var/www/html reset --hard HEAD --quiet
   git -C /var/www/html pull
   chown -Rf nginx.nginx /var/www/html
 fi
fi

# Enable custom nginx config files if they exist (HTTP only)
if [ -f /var/www/html/_conf/nginx/nginx-site.conf ]; then
  cp /var/www/html/_conf/nginx/nginx-site.conf /etc/nginx/sites-enabled/default.conf
fi

# Enable custom php-fpm.conf file if it exists
if [ -f /var/www/html/_conf/php/php-fpm.conf ]; then
  mv /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.default.conf
  cp /var/www/html/_conf/php/php-fpm.conf /usr/local/etc/php-fpm.conf
fi

# Enable custom php.ini file if it exists
if [ -f /var/www/html/_conf/php/php.ini ]; then
  mv /usr/local/etc/php/conf.d/php.ini /usr/local/etc/php/conf.d/php.ini
  cp /var/www/html/_conf/php/php.ini /usr/local/etc/php/conf.d/php.ini
fi

# Try auto install for composer
if [ -f "/var/www/html/composer.lock" ]; then
  composer install --no-dev --working-dir=/var/www/html
fi

# Display PHP error's or not
if [[ "$ERRORS" != "1" ]] ; then
 echo php_flag[display_errors] = off >> /usr/local/etc/php-fpm.conf
else
 echo php_flag[display_errors] = on >> /usr/local/etc/php-fpm.conf
fi

# Display Version Details or not
if [[ "$HIDE_NGINX_HEADERS" == "0" ]] ; then
 sed -i "s/server_tokens off;/server_tokens on;/g" /etc/nginx/nginx.conf
else
 sed -i "s/expose_php = On/expose_php = Off/g" /usr/local/etc/php/conf.d/php.ini
fi

# Enable PHP Short Open Tag
sed -i "s/short_open_tag = Off/short_open_tag = On/g" /usr/local/etc/php/conf.d/php.ini

# Increase the memory_limit
if [ ! -z "$PHP_MEM_LIMIT" ]; then
 sed -i "s/memory_limit = 128M/memory_limit = ${PHP_MEM_LIMIT}M/g" /usr/local/etc/php/conf.d/php.ini
fi

# Pass real-ip to logs when behind ELB, etc
if [[ "$REAL_IP_HEADER" == "1" ]] ; then
 sed -i "s/#real_ip_header X-Forwarded-For;/real_ip_header X-Forwarded-For;/" /etc/nginx/sites-available/default.conf
 sed -i "s/#set_real_ip_from/set_real_ip_from/" /etc/nginx/sites-available/default.conf
 if [ ! -z "$REAL_IP_FROM" ]; then
  sed -i "s#172.16.0.0/12#$REAL_IP_FROM#" /etc/nginx/sites-available/default.conf
 fi
fi

# Increase the post_max_size
if [ ! -z "$PHP_POST_MAX_SIZE" ]; then
 sed -i "s/post_max_size = 100M/post_max_size = ${PHP_POST_MAX_SIZE}M/g" /usr/local/etc/php/conf.d/php.ini
fi

# Increase the upload_max_filesize
if [ ! -z "$PHP_UPLOAD_MAX_FILESIZE" ]; then
 sed -i "s/upload_max_filesize = 100M/upload_max_filesize= ${PHP_UPLOAD_MAX_FILESIZE}M/g" /usr/local/etc/php/conf.d/php.ini
fi

if [ ! -z "$PUID" ]; then
  if [ -z "$PGID" ]; then
    PGID=${PUID}
  fi
  deluser nginx
  addgroup -g ${PGID} nginx
  adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx -u ${PUID} nginx
else
  # Always chown webroot for better mounting
  chown -Rf nginx.nginx /var/www/html
fi

# Run custom scripts
if [[ "$RUN_SCRIPTS" == "1" ]] ; then
  if [ -d "/var/www/html/scripts/" ]; then
    # make scripts executable incase they aren't
    chmod -Rf 750 /var/www/html/scripts/*
    # run scripts in number order
    for i in `ls /var/www/html/scripts/`; do /var/www/html/scripts/$i ; done
  else
    echo "Can't find script directory"
  fi
fi

# Start supervisord and services
exec /usr/bin/supervisord -n -c /etc/supervisord.conf

