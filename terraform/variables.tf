variable "context"                            { }
variable "aws_profile"                        { }
variable "aws_region"                         { }
variable "foundry_state_bucket"               { }
variable "foundry_state_key"                  { }
variable "codecommit_state_key"               { }

#---------------------------------------------------------
# Proxy server configuration
#---------------------------------------------------------
variable "proxy_log_retention_days"           { default = 365 }
variable "proxy_lb_certificate_domain_name"   { }
variable "proxy_instance_type"                { default = "t2.micro"}
variable "proxy_instance_count_min"           { default = 1 }
variable "proxy_instance_count_max"           { default = 2 }
variable "proxy_instance_count_desired"       { default = 2 }
variable "ecr_registry_hostname"              { }
variable "repo_bucket_dns_name"               { default = "repo.s3-website-us-east-1.amazonaws.com" }
variable "oauth_client_id"                    { }
variable "oauth_client_secret"                { }
variable "oauth_domain"                       { }
variable "oauth_cookie_secret"                { }

#---------------------------------------------------------
# Ivy server configuration
#---------------------------------------------------------
variable "ivy_log_retention_days"             { default = 365 }
variable "ivy_instance_type"                  { default = "t2.micro"}
variable "ivy_instance_count_min"             { default = 1 }
variable "ivy_instance_count_max"             { default = 2 }
variable "ivy_instance_count_desired"         { default = 2 }

#---------------------------------------------------------
# Upsource server configuration
#---------------------------------------------------------
variable "upsource_instance_type"             { default = "t2.micro" }
variable "upsource_log_retention_days"        { default = 365 }
variable "upsource_version"                   { }
variable "upsource_root_volume_size_gb"       { }
variable "upsource_ebs_volume_size_gb"        { }

#---------------------------------------------------------
# Toxic server configuration
#---------------------------------------------------------
variable "toxic_log_retention_days"           { default = 365 }
variable "toxic_instance_type"                { default = "t2.micro"}
variable "toxic_data_volume_size_gb"          { }
variable "toxic_docker_bytes_per_inode"       { default="4096" }
variable "toxic_docker_volume_size_gb"        { }
variable "slack_token"                        { }