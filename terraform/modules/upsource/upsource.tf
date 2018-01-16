data "terraform_remote_state" "foundry" {
  backend = "s3"
  config {
    bucket = "${var.foundry_state_bucket}"
    key    = "${var.foundry_state_key}"
    region = "${var.aws_region}"
  }
}

provider "aws" {
  region = "${var.aws_region}"
}

resource "aws_route53_record" "upsource-public-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.public_zone_id}"
  name      = "upsource"
  type      = "A"

  alias {
    name                   = "${var.proxy_lb_dns_name}"
    zone_id                = "${var.proxy_lb_zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "upsource-private-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.private_zone_id}"
  name      = "upsource"
  type      = "A"
  ttl       = "60"
  records = ["${aws_instance.upsource-instance.private_ip}"]
}

resource "aws_ebs_volume" "upsource-ebs" {
  availability_zone = "${data.terraform_remote_state.foundry.availability_zones["a"]}"
  size = "${var.upsource_ebs_volume_size_gb}"
  type = "gp2"
  tags {
    Name = "${var.context}-upsource-data"
  }
}

data "aws_ami" "amazon-linux" {
  owners = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn-ami-*-x86_64-gp2"]
  }
}

resource "aws_instance" "upsource-instance" {
  ami = "${data.aws_ami.amazon-linux.id}"
  availability_zone = "${data.terraform_remote_state.foundry.availability_zones["a"]}"
  instance_type = "${var.upsource_instance_type}"
  subnet_id = "${var.internal_subnet_ids[0]}"
  vpc_security_group_ids = [ "${aws_security_group.upsource-instance-sg.id}" ]
  user_data       = "${data.template_file.user-data-script.rendered}"
  key_name        = "${var.ec2_key_name}"
  iam_instance_profile = "${aws_iam_instance_profile.upsource-instance-profile.id}"

  root_block_device {
    volume_type = "gp2"
    volume_size = "${var.upsource_root_volume_size_gb}"
  }

  tags {
    "Name" = "${var.context}-upsource"
    "Context" = "${var.context}"
  }
}

data "aws_subnet" "internal_subnets" {
  count = "${length(var.internal_subnet_ids)}"
  id = "${element(var.internal_subnet_ids, count.index)}"
}

resource "aws_security_group" "upsource-instance-sg" {
  name   = "upsource-${var.context}"
  vpc_id = "${data.terraform_remote_state.foundry.vpc_id}"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [ "${var.proxy_security_group_id}" ]
    cidr_blocks = ["${data.aws_subnet.internal_subnets.*.cidr_block}"]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [ "${data.terraform_remote_state.foundry.jump_host_sg}", "${var.proxy_security_group_id}" ]
  }

  # Allow outbound access to NFS/EFS
  egress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound SSH
  egress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound SMTP
  egress {
    from_port   = 25
    to_port     = 25
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound SMTP
  egress {
    from_port   = 587
    to_port     = 587
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound HTTP
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound HTTPS
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "${var.context}-upsource"
    Context = "${var.context}"
  }
}

data "template_file" "user-data-script" {
  template = "${file("${path.module}/templates/upsource-bootstrap.tpl")}"
  vars {
    context               = "${var.context}"
    aws_region            = "${var.aws_region}"
    users_local_mount     = "/users"
    users_efs_target      = "${data.terraform_remote_state.foundry.user_data_efs_dns_name}"
    upsource_log_group    = "${aws_cloudwatch_log_group.upsource.name}"
    ebs_volume_id         = "${aws_ebs_volume.upsource-ebs.id}"
    upsource_ebs_device   = "${var.upsource_ebs_device}"
    upsource_data_local_mount = "/upsource"
    upsource_version      = "${var.upsource_version}"
    upsource_host_port    = "${var.upsource_host_port}"
    upsource_base_url     = "https://${aws_route53_record.upsource-public-dns.fqdn}"
  }
}

data "aws_iam_policy_document" "upsource-assume-role-policy-document" {
  statement {
    actions = [ "sts:AssumeRole" ]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = [ "ec2.amazonaws.com" ]
    }
  }
}

data "aws_iam_policy_document" "upsource-role-policy-document" {
  statement {
    effect    = "Allow"
    actions   = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "ec2:AttachVolume",
      "ec2:DescribeVolumeStatus",
      "ec2:DescribeVolumes"
    ]
    resources = [ "*" ]
  }
}

resource "aws_iam_role" "upsource-role" {
  name               = "${var.context}-upsource-role"
  path               = "/"
  assume_role_policy = "${data.aws_iam_policy_document.upsource-assume-role-policy-document.json}"
}

resource "aws_iam_instance_profile" "upsource-instance-profile" {
  name  = "${var.context}-upsource-instance-profile"
  role = "${aws_iam_role.upsource-role.name}"
}

resource "aws_iam_role_policy" "upsource-role-policy" {
  name   = "${var.context}-upsource-policy"
  role   = "${aws_iam_role.upsource-role.id}"
  policy = "${data.aws_iam_policy_document.upsource-role-policy-document.json}"
}

resource "aws_cloudwatch_log_group" "upsource" {
  name = "${var.context}-upsource"
  retention_in_days = "${var.log_retention_days}"
  tags {
    Name    = "${var.context}-upsource"
    Context = "${var.context}"
  }
}

########################################
# IAM User and access key for SES
########################################
resource "aws_iam_user" "ses-iam-user" {
  name = "${var.context}-upsource-smtp"
}
resource "aws_iam_access_key" "ses-iam-access-key" {
  user = "${aws_iam_user.ses-iam-user.name}"
}
resource "aws_iam_user_policy" "ses-user-policy" {
  name = "ses-policy"
  user = "${aws_iam_user.ses-iam-user.name}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": ["ses:SendRawEmail"],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}


output "upsource_private_dns_name" {
  value = "${aws_route53_record.upsource-private-dns.fqdn}"
}

output "upsource_public_dns_name" {
  value = "${aws_route53_record.upsource-public-dns.fqdn}"
}

output "ses-access-key-id" {
  value = "${aws_iam_access_key.ses-iam-access-key.id}"
}

output "ses-smtp-password" {
  value = "${aws_iam_access_key.ses-iam-access-key.ses_smtp_password}"
  sensitive = true
}
