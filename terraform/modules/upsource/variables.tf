variable "context"                      { }
variable "aws_region"                   { }
variable "foundry_state_bucket"         { }
variable "foundry_state_key"            { }
variable "ec2_key_name"                 { }
variable "log_retention_days"           { }
variable "upsource_instance_type"       { default = "t2.micro"}
variable "proxy_lb_dns_name"            { }
variable "proxy_lb_zone_id"             { }
variable "proxy_security_group_id"      { description = "Security group that the proxy instances belong to"}
variable "internal_subnet_ids"          { type = "list" }
variable "upsource_root_volume_size_gb" { }
variable "upsource_ebs_volume_size_gb"  { }
variable "upsource_ebs_device"          { default="/dev/xvdf" }
variable "upsource_host_port"           { description = "Port number on EC2 host that will be forwarded to upsource container", default = "80" }
variable "upsource_version"             { }
