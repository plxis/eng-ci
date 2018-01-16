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

resource "aws_alb" "proxy-lb" {
  name            = "lb-${var.context}-proxy"
  subnets         = ["${data.terraform_remote_state.foundry.public_subnets}"]
  security_groups = ["${aws_security_group.proxy-lb-sg.id}"]
  idle_timeout    = 300

  tags {
    Name    = "lb-${var.context}-proxy"
    Context = "${var.context}"
  }
}

resource "aws_alb_target_group" "proxy-tg" {
  name = "tg-${var.context}-proxy"
  port = 80
  protocol = "HTTP"
  vpc_id = "${data.terraform_remote_state.foundry.vpc_id}"

  stickiness {
    type = "lb_cookie"
  }

  health_check {
    interval = 15
    path     = "/"
    matcher = "200"
    port     = 80
    timeout  = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags {
    Name    = "tg-${var.context}-proxy"
    Context = "${var.context}"
  }
}

resource "aws_alb_listener" "proxy-lb-listener" {
  load_balancer_arn = "${aws_alb.proxy-lb.arn}"
  port = 443
  protocol = "HTTPS"
  certificate_arn = "${data.aws_acm_certificate.proxy-lb-cert.arn}"
  ssl_policy = "${var.lb_ssl_policy}"
  "default_action" {
    target_group_arn = "${aws_alb_target_group.proxy-tg.arn}"
    type = "forward"
  }
}

data "aws_acm_certificate" "proxy-lb-cert" {
  domain   = "${var.lb_certificate_domain_name}"
}

resource "aws_route53_record" "proxy-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.public_zone_id}"
  name      = "proxy"
  type      = "A"

  alias {
    name                   = "${aws_alb.proxy-lb.dns_name}"
    zone_id                = "${aws_alb.proxy-lb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "ecr-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.public_zone_id}"
  name      = "docker"
  type      = "A"

  alias {
    name                   = "${aws_alb.proxy-lb.dns_name}"
    zone_id                = "${aws_alb.proxy-lb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "repo-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.public_zone_id}"
  name      = "repo"
  type      = "A"

  alias {
    name                   = "${aws_alb.proxy-lb.dns_name}"
    zone_id                = "${aws_alb.proxy-lb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_security_group" "proxy-lb-sg" {
  name        = "${var.context}-proxy-lb-sg"
  description = "Proxy LB security group"
  vpc_id      = "${data.terraform_remote_state.foundry.vpc_id}"

  ingress {
    from_port   = 443
    to_port     = 443
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
    Name    = "sg-${var.context}-proxy-lb"
    Context = "${var.context}"
  }
}

resource "aws_autoscaling_group" "proxy-asg" {
  depends_on = ["aws_cloudwatch_log_group.proxy"]
  name                 = "asg-${var.context}-${aws_launch_configuration.proxy-lc.id}"
  max_size             = "${var.proxy_instance_count_max}"
  min_size             = "${var.proxy_instance_count_min}"
  desired_capacity     = "${var.proxy_instance_count_desired}"
  launch_configuration = "${aws_launch_configuration.proxy-lc.name}"
  vpc_zone_identifier  = [ "${data.terraform_remote_state.foundry.private_subnets}" ]
  target_group_arns    = ["${aws_alb_target_group.proxy-tg.arn}"]
  load_balancers       = [ "${aws_elb.proxy-internal-elb.id}" ]
  enabled_metrics      = [ "GroupMinSize","GroupMaxSize","GroupDesiredCapacity","GroupInServiceInstances","GroupPendingInstances","GroupStandbyInstances","GroupTerminatingInstances","GroupTotalInstances"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${var.context}-proxy"
    propagate_at_launch = true
  }

  tag {
    key                 = "Context"
    value               = "${var.context}"
    propagate_at_launch = true
  }
}

data "aws_ami_ids" "amazon-linux" {
  # NOTE: AMI IDs are returned sorted by creation time in descending order (newest first)
  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-*-x86_64-gp2"]
  }
}

resource "aws_launch_configuration" "proxy-lc" {
  name_prefix     = "lc-${var.context}-proxy-"
  image_id        = "${data.aws_ami_ids.amazon-linux.ids[0]}"
  instance_type   = "${var.proxy_instance_type}"
  security_groups = [ "${aws_security_group.proxy-instance-sg.id}" ]
  user_data       = "${data.template_file.user-data-script.rendered}"
  key_name        = "${var.ec2_key_name}"

  # Minimize downtime by creating a new launch config before destroying old one
  lifecycle {
    create_before_destroy = true
  }

  iam_instance_profile = "${aws_iam_instance_profile.proxy-profile.id}"
}

resource "aws_security_group" "proxy-instance-sg" {
  name   = "proxy-${var.context}"
  vpc_id = "${data.terraform_remote_state.foundry.vpc_id}"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [ "${aws_security_group.proxy-lb-sg.id}" ]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [ "${data.terraform_remote_state.foundry.jump_host_sg}", "${aws_elb.proxy-internal-elb.source_security_group_id}" ]
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

  # Allow outbound access to NFS (Foundry EFS)
  egress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "${var.context}-proxy"
    Context = "${var.context}"
  }
}

data "template_file" "user-data-script" {
  template = "${file("${path.module}/templates/proxy-bootstrap.tpl")}"
  vars {
    context               = "${var.context}"
    users_local_mount     = "/users"
    users_efs_target      = "${data.terraform_remote_state.foundry.user_data_efs_dns_name}"
    proxy_log_group       = "${aws_cloudwatch_log_group.proxy.name}"
    proxy_dns_name        = "${aws_route53_record.proxy-dns.fqdn}"
    ecr_registry_hostname = "${var.ecr_registry_hostname}"
    oauth_client_id       = "${var.oauth_client_id}"
    oauth_client_secret   = "${var.oauth_client_secret}"
    oauth_domain          = "${var.oauth_domain}"
    oauth_cookie_secret   = "${var.oauth_cookie_secret}"
    ivy_elb_dns_name      = "${var.ivy_elb_dns_name}"
    ivy_public_dns_name   = "${var.ivy_public_dns_name}"
    repo_public_dns_name  = "${aws_route53_record.repo-dns.fqdn}"
    repo_bucket_dns_name  = "${var.repo_bucket_dns_name}"
    upsource_private_dns_name  = "${var.upsource_private_dns_name}"
    upsource_public_dns_name   = "${var.upsource_public_dns_name}"
  }
}

data "aws_iam_policy_document" "proxy-assume-role-policy-document" {
  statement {
    actions = [ "sts:AssumeRole" ]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = [ "ec2.amazonaws.com" ]
    }
  }
}

data "aws_iam_policy_document" "proxy-role-policy-document" {
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

resource "aws_iam_role" "proxy-role" {
  name               = "${var.context}-proxy-role"
  path               = "/"
  assume_role_policy = "${data.aws_iam_policy_document.proxy-assume-role-policy-document.json}"
}

resource "aws_iam_instance_profile" "proxy-profile" {
  name  = "${var.context}-proxy-instance-profile"
  role = "${aws_iam_role.proxy-role.name}"
}

resource "aws_iam_role_policy" "proxy-role-policy" {
  name   = "${var.context}-proxy-policy"
  role   = "${aws_iam_role.proxy-role.id}"
  policy = "${data.aws_iam_policy_document.proxy-role-policy-document.json}"
}

resource "aws_cloudwatch_log_group" "proxy" {
  name = "${var.context}-proxy"
  retention_in_days = "${var.log_retention_days}"
  tags {
    Name    = "${var.context}-proxy"
    Context = "${var.context}"
  }
}

# An internal ELB for logging in (SSH) to a proxy server from within the network
resource "aws_elb" "proxy-internal-elb" {
  name            = "elb-${var.context}-proxy-internal"
  subnets         = ["${data.terraform_remote_state.foundry.private_subnets}"]
  security_groups = ["${aws_security_group.proxy-internal-elb-sg.id}"]
  internal        = true
  idle_timeout    = 330

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
    target              = "TCP:22"
    interval            = 60
  }

  tags {
    Name    = "elb-${var.context}-proxy-internal"
    Context = "${var.context}"
  }
}

resource "aws_security_group" "proxy-internal-elb-sg" {
  name        = "${var.context}-proxy-internal-elb-sg"
  description = "Proxy internal ELB security group"
  vpc_id      = "${data.terraform_remote_state.foundry.vpc_id}"

  tags {
    Name    = "sg-${var.context}-proxy-internal-elb"
    Context = "${var.context}"
  }
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
  security_group_id = "${aws_security_group.proxy-internal-elb-sg.id}"
  cidr_blocks = ["${data.aws_subnet.internal_subnets.*.cidr_block}"]
}

resource "aws_security_group_rule" "allow_ssh_to_proxy_server" {
  type            = "egress"
  from_port       = 22
  to_port         = 22
  protocol        = "tcp"
  security_group_id = "${aws_security_group.proxy-internal-elb-sg.id}"
  source_security_group_id = "${aws_security_group.proxy-instance-sg.id}"
}

resource "aws_route53_record" "proxy-internal-internal-dns" {
  zone_id   = "${data.terraform_remote_state.foundry.private_zone_id}"
  name      = "proxy"
  type      = "A"

  alias {
    name                   = "${aws_elb.proxy-internal-elb.dns_name}"
    zone_id                = "${aws_elb.proxy-internal-elb.zone_id}"
    evaluate_target_health = true
  }
}

output "proxy_lb_dns_name" {
  value = "${aws_alb.proxy-lb.dns_name}"
}

output "proxy_dns_name" {
  value = "${aws_route53_record.proxy-dns.fqdn}"
}

output "ecr_dns_name" {
  value = "${aws_route53_record.ecr-dns.fqdn}"
}

output "proxy_lb_zone_id" {
  value = "${aws_alb.proxy-lb.zone_id}"
}

output "proxy_security_group_id" {
  value = "${aws_security_group.proxy-instance-sg.id}"
}
