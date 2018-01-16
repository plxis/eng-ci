#!/bin/bash
set -e

instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Configure timezone
rm /etc/localtime && ln -s /usr/share/zoneinfo/GMT /etc/localtime

# Configure NTP
yum erase -y ntp*
yum install -y chrony
service chronyd start

# Install dependent software packages;
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
  logger -s -t upsource-bootstrap "Mounting ${users_efs_target} at ${users_local_mount}"
  mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${users_efs_target}: ${users_local_mount}
fi

# Configure shared users, cloudwatch logs, etc
if [[ -x /users/bootstrap/runOnNewHost.sh ]]; then
  /users/bootstrap/runOnNewHost.sh upsource "${context}"
else
  echo "ERROR: User bootstrap script is not available. Expected to be mounted at /users/bootstrap/runOnNewHost.sh"
fi

# Attach EBS volume and wait for it
if [[ ! -b ${upsource_ebs_device} ]]; then
  logger -s -t upsource-bootstrap "Attaching EBS volume ${ebs_volume_id} to device ${upsource_ebs_device}"
  aws ec2 attach-volume --region ${aws_region} --device ${upsource_ebs_device} --instance-id $${instance_id} --volume-id ${ebs_volume_id}
  if [[ $? == 0 ]]; then
    echo "Waiting for EBS volume to attach"
    aws ec2 wait volume-in-use --region ${aws_region} --volume-ids ${ebs_volume_id} --filters Name=attachment.status,Values=attached
  fi
fi
if [[ ! -b ${upsource_ebs_device} ]]; then
  logger -s -t upsource-bootstrap "ERROR: Device ${upsource_ebs_device} not present or is not a block device"
fi

# Mount upsource data directory from EBS (formatting if necessary)
if [ "$(file -s ${upsource_ebs_device})" == "${upsource_ebs_device}: data" ]; then
  logger -s -t upsource-bootstrap "Formatting new data volume; device=${upsource_ebs_device}"
  mkfs -t ext4 ${upsource_ebs_device}
fi
mkdir -p ${upsource_data_local_mount}
if ! mount|grep -q "${upsource_ebs_device}"; then
  mount ${upsource_ebs_device} ${upsource_data_local_mount}
fi
logger -s -t upsource-bootstrap "Mounted data EBS volume; device=${upsource_ebs_device}"

# Configure cloudwatch logs
cat > /etc/awslogs/config/upsource.conf <<EOFLOG
[upsource-frontend-all]
log_group_name=${upsource_log_group}
log_stream_name=upsource-frontend-$instance_id
datetime_format=%Y-%m-%d %H:%M:%S
file=${upsource_data_local_mount}/logs/upsource-frontend/all.log

[upsource-audit]
log_group_name=${upsource_log_group}
log_stream_name=upsource-audit-$instance_id
datetime_format=%Y-%m-%d %H:%M:%S
file=${upsource_data_local_mount}/logs/upsource-frontend/audit.log
EOFLOG
service awslogs restart

# Install and start docker engine
yum install -y docker
service docker restart

# Pull upsource image
docker pull jetbrains/upsource:${upsource_version}

# Prepare directories for upsource data
if [[ ! -d "${upsource_data_local_mount}" ]]; then
  logger -s -t upsource-bootstrap "ERROR: Upsource data mount does not exist"
  exit 1
fi
for d in data logs conf backups; do
  # Create it if it does not exist
  if [[ ! -d "${upsource_data_local_mount}/$${d}" ]]; then
    logger -s -t upsource-bootstrap "Creating upsource data directory: ${upsource_data_local_mount}/$${d}"
    mkdir -p -m 750 "${upsource_data_local_mount}/$${d}"
    # Set permissions so that the upsource container can write to it
    chown -R 13001:13001 "${upsource_data_local_mount}/$${d}"
  fi
done

# Set docker mount arguments
mounts=""
for d in data logs conf backups; do
  mounts="$${mounts} -v ${upsource_data_local_mount}/$${d}:/opt/upsource/$${d}"
done

# Set the container's base URL
#docker run -it $${mounts} -p ${upsource_host_port}:8080 jetbrains/upsource:${upsource_version} configure \
#-J-Ddisable.configuration.wizard.on.clean.install=true \
#--base-url=${upsource_base_url}

# Start upsource container
docker run -d $${mounts} -p ${upsource_host_port}:8080 jetbrains/upsource:${upsource_version}

# Create a script for starting upsource manually
cat > /usr/local/bin/upsource <<EOFSCRIPT
#!/usr/bin/env bash
docker run -d $${mounts} -p ${upsource_host_port}:8080 jetbrains/upsource:${upsource_version}
EOFSCRIPT
chmod +x /usr/local/bin/upsource
