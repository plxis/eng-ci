variable "context"                      { }
variable "aws_profile"                  { }
variable "aws_region"                   { }
variable "foundry_state_bucket"         { }
variable "foundry_state_key"            { }
variable "ec2_key_name"                 { }
variable "log_retention_days"           { }
variable "ivy_instance_type"            { default = "t2.micro"}
variable "ivy_instance_count_min"       { default = 1 }
variable "ivy_instance_count_max"       { default = 2 }
variable "ivy_instance_count_desired"   { default = 2 }
variable "proxy_lb_dns_name"            { }
variable "proxy_lb_zone_id"             { }
variable "proxy_security_group_id"      { description = "Security group that the proxy instances belong to"}
variable "internal_subnet_ids"          { type = "list" }
