data "terraform_remote_state" "foundry" {
  backend = "s3"
  config {
    bucket = "${var.foundry_state_bucket}"
    key    = "${var.foundry_state_key}"
    region = "${var.aws_region}"
    profile= "${var.aws_profile}"
  }
}

provider "aws" {
  region = "${var.aws_region}"
  profile= "${var.aws_profile}"
}

resource "aws_route53_record" "ivy-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.public_zone_id}"
  name      = "ivy"
  type      = "A"

  alias {
    name                   = "${var.proxy_lb_dns_name}"
    zone_id                = "${var.proxy_lb_zone_id}"
    evaluate_target_health = true
  }
}

# An internal ELB that the proxy server can use as a forwarding target
resource "aws_elb" "ivy-elb" {
  name            = "elb-${var.context}-ivy"
  subnets         = ["${data.terraform_remote_state.foundry.private_subnets}"]
  security_groups = ["${aws_security_group.ivy-elb-sg.id}"]
  internal        = true
  idle_timeout    = 330

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  listener {
    instance_port     = 22
    instance_protocol = "tcp"
    lb_port           = 22
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 10
    target              = "HTTP:80/"
    interval            = 15
  }

  tags {
    Name    = "elb-${var.context}-ivy"
    Context = "${var.context}"
  }
}

resource "aws_security_group" "ivy-elb-sg" {
  name        = "${var.context}-ivy-elb-sg"
  description = "Ivy (internal) ELB security group"
  vpc_id      = "${data.terraform_remote_state.foundry.vpc_id}"

  # NOTE: Ingress/Egress rules are defined in separate 'aws_security_group_rule' resources to
  #       prevent cyclic dependency between this SG and the SG used for instances behind the ELB

  tags {
    Name    = "sg-${var.context}-ivy-elb"
    Context = "${var.context}"
  }
}

resource "aws_security_group_rule" "allow_http_from_proxy_servers" {
  type            = "ingress"
  from_port       = 80
  to_port         = 80
  protocol        = "tcp"
  security_group_id = "${aws_security_group.ivy-elb-sg.id}"
  source_security_group_id = "${var.proxy_security_group_id}"
}

data "aws_subnet" "internal_subnets" {
  count = "${length(var.internal_subnet_ids)}"
  id = "${element(var.internal_subnet_ids, count.index)}"
}

resource "aws_security_group_rule" "allow_ssh_from_internal_servers" {
  type            = "ingress"
  from_port       = 22
  to_port         = 22
  protocol        = "tcp"
  security_group_id = "${aws_security_group.ivy-elb-sg.id}"
  cidr_blocks = ["${data.aws_subnet.internal_subnets.*.cidr_block}"]
}

resource "aws_security_group_rule" "allow_elb_health_check" {
  type            = "egress"
  from_port       = 80
  to_port         = 80
  protocol        = "tcp"
  security_group_id = "${aws_security_group.ivy-elb-sg.id}"
  source_security_group_id = "${aws_security_group.ivy-instance-sg.id}"
}

resource "aws_security_group_rule" "allow_ssh_to_ivy_servers" {
  type            = "egress"
  from_port       = 22
  to_port         = 22
  protocol        = "tcp"
  security_group_id = "${aws_security_group.ivy-elb-sg.id}"
  source_security_group_id = "${aws_security_group.ivy-instance-sg.id}"
}


resource "aws_route53_record" "ivy-internal-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.private_zone_id}"
  name      = "ivy"
  type      = "A"

  alias {
    name                   = "${aws_elb.ivy-elb.dns_name}"
    zone_id                = "${aws_elb.ivy-elb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_autoscaling_group" "ivy-asg" {
  depends_on = ["aws_cloudwatch_log_group.ivy"]
  name                 = "asg-${var.context}-${aws_launch_configuration.ivy-lc.id}"
  max_size             = "${var.ivy_instance_count_max}"
  min_size             = "${var.ivy_instance_count_min}"
  desired_capacity     = "${var.ivy_instance_count_desired}"
  launch_configuration = "${aws_launch_configuration.ivy-lc.name}"
  min_elb_capacity     = 1
  vpc_zone_identifier  = [ "${data.terraform_remote_state.foundry.private_subnets}" ]
  load_balancers       = [ "${aws_elb.ivy-elb.id}" ]
  enabled_metrics      = [ "GroupMinSize","GroupMaxSize","GroupDesiredCapacity","GroupInServiceInstances","GroupPendingInstances","GroupStandbyInstances","GroupTerminatingInstances","GroupTotalInstances"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${var.context}-ivy"
    propagate_at_launch = true
  }

  tag {
    key                 = "Context"
    value               = "${var.context}"
    propagate_at_launch = true
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

resource "aws_launch_configuration" "ivy-lc" {
  name_prefix     = "lc-${var.context}-ivy-"
  image_id        = "${data.aws_ami.amazon-linux.id}"
  instance_type   = "${var.ivy_instance_type}"
  security_groups = [ "${aws_security_group.ivy-instance-sg.id}" ]
  user_data       = "${data.template_file.user-data-script.rendered}"
  key_name        = "${var.ec2_key_name}"

  # Minimize downtime by creating a new launch config before destroying old one
  lifecycle {
    create_before_destroy = true
  }

  iam_instance_profile = "${aws_iam_instance_profile.ivy-profile.id}"
}

resource "aws_security_group" "ivy-instance-sg" {
  name   = "ivy-${var.context}"
  vpc_id = "${data.terraform_remote_state.foundry.vpc_id}"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [ "${var.proxy_security_group_id}", "${aws_elb.ivy-elb.source_security_group_id}" ]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [ "${data.terraform_remote_state.foundry.jump_host_sg}", "${var.proxy_security_group_id}",  "${aws_elb.ivy-elb.source_security_group_id}" ]
  }

  # Allow outbound access to NFS/EFS
  egress {
    from_port   = 2049
    to_port     = 2049
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
    Name    = "${var.context}-ivy"
    Context = "${var.context}"
  }
}

data "template_file" "user-data-script" {
  template = "${file("${path.module}/templates/ivy-bootstrap.tpl")}"
  vars {
    context               = "${var.context}"
    users_local_mount     = "/users"
    users_efs_target      = "${data.terraform_remote_state.foundry.user_data_efs_dns_name}"
    ivy_log_group         = "${aws_cloudwatch_log_group.ivy.name}"
    ivy_local_mount       = "/ivy_repo"
    ivy_efs_target        = "${aws_efs_mount_target.ivy_fs_target.0.dns_name}"
  }
}

data "aws_iam_policy_document" "ivy-assume-role-policy-document" {
  statement {
    actions = [ "sts:AssumeRole" ]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = [ "ec2.amazonaws.com" ]
    }
  }
}

data "aws_iam_policy_document" "ivy-role-policy-document" {
  statement {
    effect    = "Allow"
    actions   = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [ "*" ]
  }
}

resource "aws_iam_role" "ivy-role" {
  name               = "${var.context}-ivy-role"
  path               = "/"
  assume_role_policy = "${data.aws_iam_policy_document.ivy-assume-role-policy-document.json}"
}

resource "aws_iam_instance_profile" "ivy-profile" {
  name  = "${var.context}-ivy-instance-profile"
  role = "${aws_iam_role.ivy-role.name}"
}

resource "aws_iam_role_policy" "ivy-role-policy" {
  name   = "${var.context}-ivy-policy"
  role   = "${aws_iam_role.ivy-role.id}"
  policy = "${data.aws_iam_policy_document.ivy-role-policy-document.json}"
}

resource "aws_cloudwatch_log_group" "ivy" {
  name = "${var.context}-ivy"
  retention_in_days = "${var.log_retention_days}"
  tags {
    Name    = "${var.context}-ivy"
    Context = "${var.context}"
  }
}

resource "aws_efs_file_system" "ivy_repo_fs" {
  creation_token = "ivy-efs-${var.context}"
  encrypted      = true

  tags {
    Name    = "ivy-efs-${var.context}"
    Context = "${var.context}"
  }
}

resource "aws_security_group" "ivy_repo_efs_sg" {
  name        = "${var.context}-ivy-repo-mount"
  description = "Allow EC2 instance to mount EFS target"
  vpc_id      = "${data.terraform_remote_state.foundry.vpc_id}"

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = ["${aws_security_group.ivy-instance-sg.id}"]
  }

  tags {
    Name    = "${var.context}-ivy-repo-mount"
    Context = "${var.context}"
  }
}

resource "aws_efs_mount_target" "ivy_fs_target" {
  count           = "2"
  file_system_id  = "${aws_efs_file_system.ivy_repo_fs.id}"
  subnet_id       = "${element(data.terraform_remote_state.foundry.private_subnets, count.index)}"
  security_groups = ["${aws_security_group.ivy_repo_efs_sg.id}"]
}

output "ivy_elb_dns_name" {
  value = "${aws_elb.ivy-elb.dns_name}"
}

output "ivy_public_dns_name" {
  value = "${aws_route53_record.ivy-dns.fqdn}"
}