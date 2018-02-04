data "terraform_remote_state" "foundry" {
  backend = "s3"
  config {
    bucket = "${var.foundry_state_bucket}"
    key    = "${var.foundry_state_key}"
    region = "${var.aws_region}"
    profile= "${var.aws_profile}"
  }
}

data "terraform_remote_state" "codecommit" {
  backend = "s3"
  config {
    bucket = "${var.foundry_state_bucket}"
    key    = "${var.codecommit_state_key}"
    region = "${var.aws_region}"
    profile= "${var.aws_profile}"
  }
}


provider "aws" {
  region = "${var.aws_region}"
  profile= "${var.aws_profile}"
}

resource "aws_ecr_repository" "toxic" {
  name = "toxic"
}

resource "aws_route53_record" "toxic-public-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.public_zone_id}"
  name      = "toxic"
  type      = "A"

  alias {
    name                   = "${var.proxy_lb_dns_name}"
    zone_id                = "${var.proxy_lb_zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_alb" "toxic-lb" {
  name            = "lb-${var.context}-toxic"
  subnets         = ["${data.terraform_remote_state.foundry.private_subnets}"]
  security_groups = ["${aws_security_group.toxic-lb-sg.id}"]
  idle_timeout    = 300
  internal        = true

  tags {
    Name    = "lb-${var.context}-toxic"
    Context = "${var.context}"
  }
}

resource "aws_alb_target_group" "toxic-tg" {
  name = "tg-${var.context}-toxic"
  port = 80
  protocol = "HTTP"
  vpc_id = "${data.terraform_remote_state.foundry.vpc_id}"

  stickiness {
    type = "lb_cookie"
  }

  health_check {
    interval = 15
    path     = "/"
    matcher = "302"
    port     = 80
    timeout  = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags {
    Name    = "tg-${var.context}-toxic"
    Context = "${var.context}"
  }
}

resource "aws_alb_listener" "toxic-lb-listener" {
  load_balancer_arn = "${aws_alb.toxic-lb.arn}"
  port = 80
  protocol = "HTTP"
  "default_action" {
    target_group_arn = "${aws_alb_target_group.toxic-tg.arn}"
    type = "forward"
  }
}

resource "aws_security_group" "toxic-lb-sg" {
  name        = "${var.context}-toxic-lb-sg"
  description = "Toxic LB security group"
  vpc_id      = "${data.terraform_remote_state.foundry.vpc_id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "sg-${var.context}-toxic-lb"
    Context = "${var.context}"
  }
}

data "aws_subnet" "internal_subnets" {
  count = "${length(var.internal_subnet_ids)}"
  id = "${element(var.internal_subnet_ids, count.index)}"
}

resource "aws_route53_record" "toxic-internal-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.private_zone_id}"
  name      = "toxic"
  type      = "A"

  alias {
    name                   = "${aws_alb.toxic-lb.dns_name}"
    zone_id                = "${aws_alb.toxic-lb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_autoscaling_group" "toxic-asg" {
  depends_on = ["aws_cloudwatch_log_group.toxic"]
  name                 = "asg-${var.context}-${aws_launch_configuration.toxic-lc.id}"
  max_size             = "${var.toxic_instance_count_max}"
  min_size             = "${var.toxic_instance_count_min}"
  desired_capacity     = "${var.toxic_instance_count_desired}"
  launch_configuration = "${aws_launch_configuration.toxic-lc.name}"
  vpc_zone_identifier  = [ "${data.terraform_remote_state.foundry.private_subnets[0]}" ]
  target_group_arns    = [ "${aws_alb_target_group.toxic-tg.arn}" ]
  enabled_metrics      = [ "GroupMinSize","GroupMaxSize","GroupDesiredCapacity","GroupInServiceInstances","GroupPendingInstances","GroupStandbyInstances","GroupTerminatingInstances","GroupTotalInstances"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${var.context}-toxic"
    propagate_at_launch = true
  }

  tag {
    key                 = "Context"
    value               = "${var.context}"
    propagate_at_launch = true
  }
}

resource "aws_launch_configuration" "toxic-lc" {
  name_prefix     = "lc-${var.context}-toxic-"
  image_id        = "${data.aws_ami.amazon-linux.id}"
  instance_type   = "${var.toxic_instance_type}"
  security_groups = [ "${aws_security_group.toxic-instance-sg.id}" ]
  user_data       = "${data.template_file.user-data-script.rendered}"
  key_name        = "${var.ec2_key_name}"

  # Destroy old instance first since we cannot have multiple instances mounting 
  # EBS volumes concurrently.
  lifecycle {
    create_before_destroy = false
  }

  iam_instance_profile = "${aws_iam_instance_profile.instance-profile.id}"
}

data "aws_ami" "amazon-linux" {
  owners = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn-ami-*-x86_64-gp2"]
  }
}

resource "aws_ebs_volume" "toxic-data-ebs" {
  availability_zone = "${data.terraform_remote_state.foundry.availability_zones["a"]}"
  size = "${var.toxic_data_volume_size_gb}"
  type = "gp2"
  tags {
    Name = "${var.context}-ToxicData"
  }
}

resource "aws_ebs_volume" "toxic-docker-ebs" {
  availability_zone = "${data.terraform_remote_state.foundry.availability_zones["a"]}"
  size = "${var.toxic_docker_volume_size_gb}"
  type = "gp2"
  tags {
    Name = "${var.context}-ToxicDockerData"
  }
}


resource "aws_security_group" "toxic-instance-sg" {
  name   = "toxic-${var.context}"
  vpc_id = "${data.terraform_remote_state.foundry.vpc_id}"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [ "${aws_security_group.toxic-lb-sg.id}" ]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [ "${data.terraform_remote_state.foundry.jump_host_sg}" ]
  }

  # Allow all outbound access
  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "toxic-${var.context}"
    Context = "${var.context}"
  }
}

data "template_file" "user-data-script" {
  template = "${file("${path.module}/templates/toxic-bootstrap.tpl")}"
  vars {
    context               = "${var.context}"
    aws_region            = "${var.aws_region}"
    users_local_mount     = "/users"
    users_efs_target      = "${data.terraform_remote_state.foundry.user_data_efs_dns_name}"
    toxic_log_group       = "${aws_cloudwatch_log_group.toxic.name}"
    toxic_data_volume     = "${aws_ebs_volume.toxic-data-ebs.id}"
    toxic_data_device     = "${var.toxic_data_device}"
    toxic_docker_volume   = "${aws_ebs_volume.toxic-docker-ebs.id}"
    toxic_docker_device   = "${var.toxic_docker_device}"
    toxic_docker_bytes_per_inode = "${var.toxic_docker_bytes_per_inode}"
    aws_codecommit_ssh_key_id = "${data.terraform_remote_state.codecommit.toxic-ssh-key-id}"
    aws_codecommit_ssh_private_key = "${base64encode(data.terraform_remote_state.codecommit.toxic-private-key)}"
    slack_token     = "${var.slack_token}"
    smtp_username = "${aws_iam_access_key.ses-iam-access-key.id}"
    smtp_password = "${aws_iam_access_key.ses-iam-access-key.ses_smtp_password}"
  }
}

data "aws_iam_policy_document" "instance-assume-role-policy-document" {
  statement {
    actions = [ "sts:AssumeRole" ]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = [ "ec2.amazonaws.com" ]
    }
  }
}

data "aws_iam_policy_document" "instance-role-policy-document" {
  statement {
    effect    = "Allow"
    actions   = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "ec2:AttachVolume",
      "ec2:DescribeVolumeStatus",
      "ec2:DescribeVolumes",
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:BatchGetImage"
    ]
    resources = [ "*" ]
  }
}

resource "aws_iam_role" "instance-role" {
  name               = "${var.context}-toxic-role"
  path               = "/"
  assume_role_policy = "${data.aws_iam_policy_document.instance-assume-role-policy-document.json}"
}

resource "aws_iam_instance_profile" "instance-profile" {
  name  = "${var.context}-toxic-instance-profile"
  role = "${aws_iam_role.instance-role.name}"
}

resource "aws_iam_role_policy" "instance-role-policy" {
  name   = "${var.context}-toxic-policy"
  role   = "${aws_iam_role.instance-role.id}"
  policy = "${data.aws_iam_policy_document.instance-role-policy-document.json}"
}

resource "aws_cloudwatch_log_group" "toxic" {
  name = "${var.context}-toxic"
  retention_in_days = "${var.log_retention_days}"
  tags {
    Name    = "${var.context}-toxic"
    Context = "${var.context}"
  }
}

########################################
# IAM User and access key for SES
########################################
resource "aws_iam_user" "ses-iam-user" {
  name = "${var.context}-toxic-smtp"
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


output "toxic_public_dns_name" {
  value = "${aws_route53_record.toxic-public-dns.fqdn}"
}

output "toxic_private_dns_name" {
  value = "${aws_route53_record.toxic-internal-dns.fqdn}"
}

output "ses-access-key-id" {
  value = "${aws_iam_access_key.ses-iam-access-key.id}"
}

output "ses-smtp-password" {
  value = "${aws_iam_access_key.ses-iam-access-key.ses_smtp_password}"
  sensitive = true
}
