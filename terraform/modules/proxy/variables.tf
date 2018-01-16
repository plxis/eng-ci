variable "context"                      { }
variable "aws_region"                   { }
variable "foundry_state_bucket"         { }
variable "foundry_state_key"            { }
variable "ec2_key_name"                 { }
variable "log_retention_days"           { }
variable "internal_subnet_ids"          { type="list" }
variable "proxy_instance_type"          { default = "t2.micro"}
variable "proxy_instance_count_min"     { default = 1 }
variable "proxy_instance_count_max"     { default = 2 }
variable "proxy_instance_count_desired" { default = 2 }
variable "lb_certificate_domain_name"   { }
variable "lb_ssl_policy"                { default = "ELBSecurityPolicy-TLS-1-2-2017-01" }
variable "ecr_registry_hostname"        { }
variable "oauth_client_id"              { }
variable "oauth_client_secret"          { }
variable "oauth_domain"                 { }
variable "oauth_cookie_secret"          { }
variable "ivy_elb_dns_name"             { }
variable "ivy_public_dns_name"          { }
variable "repo_bucket_dns_name"         { }
variable "upsource_private_dns_name"    { }
variable "upsource_public_dns_name"     { }
