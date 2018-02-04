provider "aws" {
  region = "${var.aws_region}"
  profile= "${var.aws_profile}"
}

terraform {
  backend "s3" { }
}

data "terraform_remote_state" "foundry" {
  backend = "s3"
  config {
    bucket = "${var.foundry_state_bucket}"
    key    = "${var.foundry_state_key}"
    region = "${var.aws_region}"
    profile= "${var.aws_profile}"
  }
}

resource "tls_private_key" "ec2-tls-key" {
  algorithm   = "RSA"
}

resource "aws_key_pair" "ec2-key" {
  key_name   = "${var.context}-key"
  public_key = "${tls_private_key.ec2-tls-key.public_key_openssh}"
}

module "proxy-server" {
  source = "./modules/proxy"
  context = "${var.context}"
  aws_region = "${var.aws_region}"
  aws_profile = "${var.aws_profile}"
  foundry_state_bucket = "${var.foundry_state_bucket}"
  foundry_state_key = "${var.foundry_state_key}"
  ec2_key_name = "${aws_key_pair.ec2-key.key_name}"
  internal_subnet_ids = "${data.terraform_remote_state.foundry.private_subnets}"
  lb_certificate_domain_name = "${var.proxy_lb_certificate_domain_name}"
  log_retention_days = "${var.proxy_log_retention_days}"
  proxy_instance_type = "${var.proxy_instance_type}"
  proxy_instance_count_min = "${var.proxy_instance_count_min}"
  proxy_instance_count_max = "${var.proxy_instance_count_max}"
  proxy_instance_count_desired = "${var.proxy_instance_count_desired}"
  ecr_registry_hostname = "${var.ecr_registry_hostname}"
  oauth_client_id = "${var.oauth_client_id}"
  oauth_client_secret = "${var.oauth_client_secret}"
  oauth_domain = "${var.oauth_domain}"
  oauth_cookie_secret = "${var.oauth_cookie_secret}"
  ivy_elb_dns_name = "${module.ivy-servers.ivy_elb_dns_name}"
  ivy_public_dns_name = "${module.ivy-servers.ivy_public_dns_name}"
  toxic_public_dns_name = "${module.toxic-server.toxic_public_dns_name}"
  toxic_private_dns_name = "${module.toxic-server.toxic_private_dns_name}"
  repo_bucket_dns_name = "${var.repo_bucket_dns_name}"
  upsource_private_dns_name = "${module.upsource-server.upsource_private_dns_name}"
  upsource_public_dns_name = "${module.upsource-server.upsource_public_dns_name}"
}

module "ivy-servers" {
  source = "./modules/ivy"
  context = "${var.context}"
  aws_region = "${var.aws_region}"
  aws_profile = "${var.aws_profile}"
  foundry_state_bucket = "${var.foundry_state_bucket}"
  foundry_state_key = "${var.foundry_state_key}"
  ec2_key_name = "${aws_key_pair.ec2-key.key_name}"
  log_retention_days = "${var.ivy_log_retention_days}"
  ivy_instance_type = "${var.ivy_instance_type}"
  ivy_instance_count_min = "${var.ivy_instance_count_min}"
  ivy_instance_count_max = "${var.ivy_instance_count_max}"
  ivy_instance_count_desired = "${var.ivy_instance_count_desired}"
  proxy_lb_dns_name = "${module.proxy-server.proxy_lb_dns_name}"
  proxy_lb_zone_id = "${module.proxy-server.proxy_lb_zone_id}"
  proxy_security_group_id = "${module.proxy-server.proxy_security_group_id}"
  internal_subnet_ids = "${data.terraform_remote_state.foundry.private_subnets}"
}

module "toxic-server" {
  source = "./modules/toxic"
  context = "${var.context}"
  aws_region = "${var.aws_region}"
  aws_profile = "${var.aws_profile}"
  foundry_state_bucket = "${var.foundry_state_bucket}"
  foundry_state_key = "${var.foundry_state_key}"
  codecommit_state_key = "${var.codecommit_state_key}"
  ec2_key_name = "${aws_key_pair.ec2-key.key_name}"
  log_retention_days = "${var.toxic_log_retention_days}"
  toxic_instance_type = "${var.toxic_instance_type}"
  toxic_data_volume_size_gb = "${var.toxic_data_volume_size_gb}"
  toxic_docker_bytes_per_inode = "${var.toxic_docker_bytes_per_inode}"
  toxic_docker_volume_size_gb = "${var.toxic_docker_volume_size_gb}"
  proxy_lb_dns_name = "${module.proxy-server.proxy_lb_dns_name}"
  proxy_lb_zone_id = "${module.proxy-server.proxy_lb_zone_id}"
  proxy_security_group_id = "${module.proxy-server.proxy_security_group_id}"
  internal_subnet_ids = "${data.terraform_remote_state.foundry.private_subnets}"
  slack_token = "${var.slack_token}"
}

module "upsource-server" {
  source = "./modules/upsource"
  context = "${var.context}"
  aws_region = "${var.aws_region}"
  aws_profile = "${var.aws_profile}"
  foundry_state_bucket = "${var.foundry_state_bucket}"
  foundry_state_key = "${var.foundry_state_key}"
  ec2_key_name = "${aws_key_pair.ec2-key.key_name}"
  log_retention_days = "${var.upsource_log_retention_days}"
  upsource_instance_type = "${var.upsource_instance_type}"
  proxy_lb_dns_name = "${module.proxy-server.proxy_lb_dns_name}"
  proxy_lb_zone_id = "${module.proxy-server.proxy_lb_zone_id}"
  proxy_security_group_id = "${module.proxy-server.proxy_security_group_id}"
  internal_subnet_ids = "${data.terraform_remote_state.foundry.private_subnets}"
  upsource_host_port = "80"
  upsource_version = "${var.upsource_version}"
  upsource_root_volume_size_gb = "${var.upsource_root_volume_size_gb}"
  upsource_ebs_volume_size_gb = "${var.upsource_ebs_volume_size_gb}"
}

output "ssh_key" {
  value = "${tls_private_key.ec2-tls-key.private_key_pem}"
  sensitive = true
}

output "proxy_lb_dns_name" {
  value = "${module.proxy-server.proxy_lb_dns_name}"
}

output "proxy_dns_name" {
  value = "${module.proxy-server.proxy_dns_name}"
}

output "ecr_dns_name" {
  value = "${module.proxy-server.ecr_dns_name}"
}

output "ivy_dns_name" {
  value = "${module.ivy-servers.ivy_public_dns_name}"
}

output "upsource_dns_name" {
  value = "${module.upsource-server.upsource_public_dns_name}"
}

output "upsource_smtp_username" {
  value = "${module.upsource-server.ses-access-key-id}"
}

output "upsource_smtp_password" {
  value = "${module.upsource-server.ses-smtp-password}"
  sensitive = true
}

output "smtp_server_hostname" {
  value = "email-smtp.${var.aws_region}.amazonaws.com"
}
