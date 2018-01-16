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
  yum install -y awslogs nfs-utils
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

# Mount ivy repo directory from EFS
if [[ ! -d "${ivy_local_mount}" ]]; then
  mkdir -p "${ivy_local_mount}"
  mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${ivy_efs_target}: ${ivy_local_mount}
  logger -t ivy-bootstrap "Mounted ivy repo EFS share; mount=${ivy_local_mount}; target=${ivy_efs_target}"
fi

# Configure shared users, cloudwatch logs, etc
if [[ -x /users/bootstrap/runOnNewHost.sh ]]; then
  /users/bootstrap/runOnNewHost.sh ivy "${context}"
else
  echo "ERROR: User bootstrap script is not available. Expected to be mounted at /users/bootstrap/runOnNewHost.sh"
fi

# Configure cloudwatch logs
cat > /etc/awslogs/config/ivy.conf <<EOFLOG
[ivy-access]
log_group_name=${ivy_log_group}
log_stream_name=ivy-access-$instance_id
datetime_format=%Y-%m-%dT%H:%M:%S%z
file=/var/log/nginx/access.log

[ivy-error]
log_group_name=${ivy_log_group}
log_stream_name=ivy-error-$instance_id
datetime_format=%Y/%m/%d %H:%M:%S
file=/var/log/nginx/error.log
EOFLOG
service awslogs restart

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

  access_log  /var/log/nginx/access.log main;

  index   index.html index.htm;

  # Don't include any server version information in headers or error pages.
  server_tokens off;

  server {

    listen 80 default_server;

    location /repo {
      alias ${ivy_local_mount};
      autoindex on;
    }
  }
}
EOFNGINX

# Clear the default index and error pages
truncate -s 0 /usr/share/nginx/html/index.html
echo "Not Found" > /usr/share/nginx/html/404.html
echo "Server Error" > /usr/share/nginx/html/50x.html
chmod -R a+r /usr/share/nginx/html/

service nginx restart
