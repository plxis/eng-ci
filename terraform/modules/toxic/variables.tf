variable "context"                                  { }
variable "aws_profile"                              { }
variable "aws_region"                               { }
variable "foundry_state_bucket"                     { }
variable "foundry_state_key"                        { }
variable "codecommit_state_key"                     { }
variable "ec2_key_name"                             { }
variable "log_retention_days"                       { }
variable "toxic_instance_type"                      { default = "t2.micro"}
variable "toxic_instance_count_min"                 { default = 1 }
variable "toxic_instance_count_max"                 { default = 1 }
variable "toxic_instance_count_desired"             { default = 1 }
variable "proxy_lb_dns_name"                        { }
variable "proxy_lb_zone_id"                         { }
variable "proxy_security_group_id"                  { description = "Security group that the proxy instances belong to"}
variable "internal_subnet_ids"                      { type = "list" }
variable "toxic_data_device"                        { default="/dev/xvdg" }
variable "toxic_data_volume_size_gb"                { }
variable "toxic_docker_device"                      { default="/dev/xvdf" }
variable "toxic_docker_bytes_per_inode"             { }
variable "toxic_docker_volume_size_gb"              { }
variable "slack_token"                              { }
