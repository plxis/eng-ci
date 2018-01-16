#!/bin/bash
set -e

instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Configure timezone
rm /etc/localtime && ln -s /usr/share/zoneinfo/GMT /etc/localtime

# Configure NTP
yum erase -y ntp*
yum install -y chrony
service chronyd start

# Install dependent software packages; only jq and awslogs are mandatory for all hosts.
yum update -y
result=1
attempt=0
while [[ $attempt -lt 25 && $result -ne 0 ]]; do
  yum install -y jq awslogs nfs-utils
  result=$?
  [ $result -ne 0 ] && sleep 5
  attempt=$((attempt+1))
done

# Mount EFS targets
if [[ ! -d "${users_local_mount}" ]]; then
  mkdir -p "${users_local_mount}"
  echo "Mounting ${users_efs_target} at ${users_local_mount}"
  mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${users_efs_target}: ${users_local_mount}
fi

# Configure shared users, cloudwatch logs, etc
if [[ -x /users/bootstrap/runOnNewHost.sh ]]; then
  /users/bootstrap/runOnNewHost.sh proxy "${context}"
else
  echo "ERROR: User bootstrap script is not available. Expected to be mounted at /users/bootstrap/runOnNewHost.sh"
fi

# Configure cloudwatch logs for proxy
cat > /etc/awslogs/config/proxy.conf <<EOFLOG
[proxy-access]
log_group_name=${proxy_log_group}
log_stream_name=proxy-access-$instance_id
datetime_format=%Y-%m-%dT%H:%M:%S%z
file=/var/log/nginx/access.log

[proxy-error]
log_group_name=${proxy_log_group}
log_stream_name=proxy-error-$instance_id
datetime_format=%Y/%m/%d %H:%M:%S
file=/var/log/nginx/error.log
EOFLOG
service awslogs restart

# Automatically recycle this host daily. Note that this host is using GMT timezone.
crontab << \RECYCLEEOF
00 09 * * * /sbin/shutdown -P +5 "This proxy host is being automatically recycled; self-destruct sequence is currently in progress."
RECYCLEEOF

# Install oauth2_proxy
wget -qO oauth2_proxy.tar.gz https://github.com/bitly/oauth2_proxy/releases/download/v2.2/oauth2_proxy-2.2.0.linux-amd64.go1.8.1.tar.gz
tar xf oauth2_proxy.tar.gz --strip=1 -C /usr/local/bin
adduser oauth2_proxy
cat > /etc/init.d/oauth2_proxy <<\EOFOAUTH2PROXY
#!/bin/bash
#
# oauth2_proxy
#
# chkconfig: 35 85 15
# description: Authenticate proxy requests with Google G-Suite
# processname: oauth2_proxy
# pidfile: /var/run/oauth2_proxy.pid
PROG_NAME=oauth2_proxy
PROG_USER=$PROG_NAME

# Source function library.
. /etc/rc.d/init.d/functions

# Get config.
. /etc/sysconfig/network

# Check that networking is up.
[ "$NETWORKING" = "no" ] && exit 0

bin=/usr/local/bin/$PROG_NAME

startup="$bin -config=/etc/$PROG_NAME.cfg"
shutdown="killall $PROG_NAME"

RETVAL=0
start(){
 action $"Starting $PROG_NAME service: "
 touch /var/log/oauth2_proxy.log
 chown oauth2_proxy:oauth2_proxy /var/log/oauth2_proxy.log
 su - $PROG_USER -c "$startup >> /var/log/oauth2_proxy.log 2>&1 &"
 RETVAL=$?
 echo
 [ $RETVAL -eq 0 ] && touch /var/lock/subsys/$PROG_NAME
 return $RETVAL
}

stop(){
 action $"Stopping $PROG_NAME service: "
 su - $PROG_USER -c "$shutdown"
 RETVAL=$?
 echo
 [ $RETVAL -eq 0 ] && rm -f /var/lock/subsys/$PROG_NAME
 return $RETVAL
}

status(){
 numproc=$(ps -ef | grep "$startup" | grep -v grep | wc -l)
 if [ $numproc -gt 0 ]; then
  echo "$PROG_NAME is running..."
  else
  echo "$PROG_NAME is stopped..."
 fi
}

restart(){
  stop
  start
}


# See how we were called.
case "$1" in
start)
 start
 ;;
stop)
 stop
 ;;
status)
 status
 ;;
restart)
 restart
 ;;
*)
 echo $"Usage: $0 {start|stop|status|restart}"
 RETVAL=3
esac

exit $RETVAL
EOFOAUTH2PROXY
chmod a+x /etc/init.d/oauth2_proxy

cat > /etc/oauth2_proxy.cfg <<EOFOAUTH2PROXYCFG
client_id = "${oauth_client_id}"
client_secret = "${oauth_client_secret}"
provider = "google"
cookie_secret = "${oauth_cookie_secret}"
cookie_secure = true
cookie_refresh = "1h"
set_xauthrequest = true
email_domains = [ "${oauth_domain}" ]
upstreams = ["http://does/not/matter/since/we/only/use/oauth2_proxy/auth/not/redirect"]
EOFOAUTH2PROXYCFG
chown oauth2_proxy:oauth2_proxy /etc/oauth2_proxy.cfg
chmod 600 /etc/oauth2_proxy.cfg
chkconfig --add oauth2_proxy
service oauth2_proxy start

# Install nginx
yum install -y nginx

# Configure nginx
nameserver=$(cat /etc/resolv.conf |grep nameserver|awk '{print $2}')
cat > /etc/nginx/nginx.conf <<EOFNGINX
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /var/run/nginx.pid;

# Load dynamic modules. See /usr/share/doc/nginx/README.dynamic.
#include /usr/share/nginx/modules/*.conf;

events {
  worker_connections 1024;
}

http {
  # resolve using AWS DNS or Google DNS(8.8.8.8 8.8.4.4)
  resolver $nameserver 8.8.8.8 8.8.4.4;

  log_format  main  '\$remote_addr - \$remote_user [\$time_iso8601] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
  log_format upstreamlog '[\$time_iso8601] \$remote_addr - \$remote_user - \$host - \$http_x_forwarded_for - \$server_name to: \$upstream_addr: \$request \$status upstream_response_time \$upstream_response_time msec \$msec request_time \$request_time';

  access_log  /var/log/nginx/access.log upstreamlog;

  index   index.html index.htm;

  # Don't include any server version information in headers or error pages.
  server_tokens off;

  server {

    listen 80 default_server;
    server_name ${proxy_dns_name};

    location /v2 {

      set \$upstream           https://${ecr_registry_hostname};

      proxy_pass              \$upstream;
      #proxy_redirect          \$upstream https://\$host;

      proxy_set_header        Authorization        \$http_authorization;
      proxy_set_header        Www-Authenticate     \$http_www_authenticate;
      proxy_pass_header       Authorization;
      proxy_pass_header       Www-Authenticate;

      client_max_body_size    0;
      proxy_connect_timeout   300s;
      proxy_read_timeout      300s;
      proxy_send_timeout      300s;
      send_timeout            300s;
      chunked_transfer_encoding on;

    }
  }

  server {
    listen                     80;
    server_name                ${ivy_public_dns_name};
    location / {
      set \$upstream           http://${ivy_elb_dns_name};
      proxy_pass               \$upstream;
      client_max_body_size     0;
      proxy_connect_timeout    300s;
      proxy_read_timeout       300s;
      proxy_send_timeout       300s;
      send_timeout             300s;
      chunked_transfer_encoding on;
      auth_basic               "JumpPass Authentication Required";
      auth_basic_user_file     ${users_local_mount}/etc/jumppasswd;
    }
  }

  server  {
    listen  80;
    server_name  ${repo_public_dns_name};
    location  / {
      proxy_pass               http://${repo_bucket_dns_name}/;
      auth_basic               "JumpPass Authentication Required";
      auth_basic_user_file     ${users_local_mount}/etc/jumppasswd;
    }
  }

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
  }

  server {
    listen                     80;
    server_name                ${upsource_public_dns_name};
    location /oauth2/ {
      proxy_pass               http://127.0.0.1:4180;
      proxy_set_header         Host \$host;
      proxy_set_header         X-Real-IP \$remote_addr;
      proxy_set_header         X-Scheme  \$scheme;
      proxy_set_header         X-Auth-Request-Redirect \$request_uri;
    }
    location  / {
      set \$upstream           http://${upsource_private_dns_name};
      proxy_pass               \$upstream;
      auth_request_set         \$auth_cookie \$upstream_http_set_cookie;
      add_header               Set-Cookie \$auth_cookie;
      auth_request             /oauth2/auth;
      error_page               401 = /oauth2/sign_in;

      proxy_set_header X-Forwarded-Host \$http_host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_http_version 1.1;

      # to proxy WebSockets in nginx
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_pass_header Sec-Websocket-Extensions;
    }
  }
}
EOFNGINX

# Clear the default index and error pages
truncate -s 0 /usr/share/nginx/html/index.html
echo "Not Found" > /usr/share/nginx/html/404.html
echo "Server Error" > /usr/share/nginx/html/50x.html
chmod -R a+r /usr/share/nginx/html/

# Add nginx user to jumppasswd group for access to the jumppasswd file
getent group jumppasswd | grep nginx || usermod -a -G jumppasswd nginx

service nginx restart
