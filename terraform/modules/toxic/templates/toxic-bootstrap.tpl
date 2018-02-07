#!/bin/bash
instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Configure timezone
rm /etc/localtime && ln -s /usr/share/zoneinfo/GMT /etc/localtime

# Configure NTP
yum erase -y ntp*

# Install dependent software
yum update -y
result=1
attempt=0
while [[ $attempt -lt 25 && $result -ne 0 ]]; do
  yum install -y awslogs nfs-utils jq openssh chrony docker
  result=$?
  [ $result -ne 0 ] && sleep 5
  attempt=$((attempt+1))
done
service chronyd start

# EFS Setup
# Mount EFS targets
if [[ ! -d "${users_local_mount}" ]]; then
  mkdir -p "${users_local_mount}"
  echo "Mounting ${users_efs_target} at ${users_local_mount}"
  mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${users_efs_target}: ${users_local_mount}
fi

# Common instance setup (shared users, cloudwatch logs, etc)
if [[ -x /users/bootstrap/runOnNewHost.sh ]]; then
  /users/bootstrap/runOnNewHost.sh toxic "${context}"
else
  echo "ERROR: Missing /users/bootstrap/runOnNewHost.sh"
fi

# Attach EBS volume and wait for it
attach_ebs_volume() {
  volume_id=$1
  device=$2
  descr=$3
  result=1
  attempt=0
  while [[ $attempt -lt 25 && $result -ne 0 ]]; do
    logger -s -t toxic-bootstrap "Attaching $${descr} EBS volume $${volume_id} to device $${device}"
    aws ec2 attach-volume --region ${aws_region} --device $${device} --instance-id $${instance_id} --volume-id $${volume_id}
    logger -s -t toxic-bootstrap "Waiting for $${descr} EBS volume $${volume_id}"
    aws ec2 wait volume-in-use --region ${aws_region} --volume-ids $${volume_id} --filters Name=attachment.status,Values=attached
    if [[ ! -b $${device} ]]; then
      logger -s -t toxic-bootstrap "Failed to detect $${descr} EBS volume $${volume_id} at device $${device}"
      sleep 5
    else
      logger -s -t toxic-bootstrap "Successfully attached $${descr} EBS volume $${volume_id} at device $${device}"
      result=0
    fi
    attempt=$((attempt+1))
  done
  if [[ ! -b $${device} ]]; then
    logger -s -t toxic-bootstrap "ERROR: Device $${device} not present or is not a block device"
  fi
}

# Mount EBS volume (formatting if necessary)
mount_ebs() {
  device=$1
  shift
  mount_point=$1
  shift
  fs_args="$@"

  if [ "$(file -Ls $${device})" == "$${device}: data" ]; then
    logger -s -t toxic-bootstrap "Formatting EBS volume; device=$${device}"
    mkfs -t ext4 $${fs_args} $${device}
  fi
  mkdir -p $${mount_point}
  if ! mount|grep -q "$${device}"; then
    mount $${device} $${mount_point}
  fi
  logger -s -t toxic-bootstrap "Mounted EBS volume $${device} at $${mount_point}"
}

# Attach and mount toxic data EBS volume
attach_ebs_volume ${toxic_data_volume} ${toxic_data_device} "Toxic data"
mount_ebs ${toxic_data_device} /data

# Attach and mount docker data EBS volume
attach_ebs_volume ${toxic_docker_volume} ${toxic_docker_device} "Docker data"
mount_ebs ${toxic_docker_device} /var/lib/docker -i ${toxic_docker_bytes_per_inode}

# Cloudwatch logs Setup
cat > /etc/awslogs/config/toxic.conf <<EOFLOG
[toxic-access]
log_group_name=${toxic_log_group}
log_stream_name=toxic-access-$instance_id
datetime_format=%Y-%m-%d %H:%M:%S,%f
file=/opt/toxic/log/toxic-web.log

[toxic-app]
log_group_name=${toxic_log_group}
log_stream_name=toxic-app-$instance_id
datetime_format=%Y-%m-%d %H:%M:%S,%f
file=/opt/toxic/log/toxic.log
EOFLOG
service awslogs restart

useradd -d /home/toxic -m -u 2000 -U -G docker toxic

mkdir -p /data/log
chown -R toxic:toxic /data

mkdir -p /home/toxic/.ssh
cat > /home/toxic/.ssh/config <<EOFVARS
ServerAliveInterval 120
UserKnownHostsFile=/dev/null
StrictHostKeyChecking=no
Host git.eng.mycompany.invalid
User ${aws_codecommit_ssh_key_id}
IdentityFile ~/.ssh/id_rsa
EOFVARS
echo "${aws_codecommit_ssh_private_key}" | base64 -d > /home/toxic/.ssh/id_rsa
chmod 0600 /home/toxic/.ssh/id_rsa
chmod 0700 /home/toxic/.ssh

cat > /home/toxic/toxic-secure.properties <<EOFVARS
configRepoType=toxic.job.GitRepository
configRepoUrl=ssh://git.eng.mycompany.invalid/v1/repos/toxicjob
smtpUsername=${smtp_username}
smtpPassword=${smtp_password}
slack.token=${slack_token}
EOFVARS
chmod 0600 /home/toxic/toxic-secure.properties
chown -R toxic:toxic /home/toxic

service docker restart
$(aws --region ${aws_region} ecr get-login --no-include-email)
docker pull 274478159094.dkr.ecr.us-east-1.amazonaws.com/toxic:latest
docker run -d --privileged -p 80:8001 \
  -v /home/toxic/.ssh:/home/toxic/.ssh \
  -v /home/toxic/toxic-secure.properties:/opt/toxic/conf/toxic-secure.properties \
  -v /data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  274478159094.dkr.ecr.us-east-1.amazonaws.com/toxic:latest
