# eng-ci

This repository contains example Terraform configurations for managing software engineering tooling with AWS infrastructure. The sibling 'codecommit' repository works together with this project. The following hosts are provided:

* **proxy** - load-balanced hosts will proxy public access into the internal tools, such as Upsource. nginx is provides the proxy functionality
* **ivy** - these load-balanced hosts provide libraries and other artifacts for projects that depend on external resources.
* **upsource** - this host runs the Upsource container.

Each of the above hosts will install their required software automatically and be in a running state after Terraform completes the provisioning of the environment.

Note that eng-ci is dependent upon Foundry, another sibling project, being already provisioned and properly configured.

As with the other projects, this repository and contents within are presented as example templates for other teams looking to standup a cloud-based software development infrastructure. It is not intended to be a complete turn-key, working solution. 

## Example Usage

Create a `terraform/vars` file and provide values for non-default variables (to override default variables, refer to `terraform/variables.tf`):

```json
context              = "example-stack"
aws_region           = "us-east-1"
foundry_state_bucket = "tf-state-bucket"
foundry_state_key    = "foundry.tfstate"

#---------------------------------------------------------
# Proxy server configuration
#---------------------------------------------------------
proxy_lb_certificate_domain_name = "*.acme.com"
ecr_registry_hostname            = "1234567890"  # As in 1234567890.dkr.ecr.us-east-1.amazonaws.com
repo_bucket_dns_name             = "my-acme-repo.s3-website-us-east-1.amazonaws.com"
oauth_client_id                  = "MY_CLIENT_ID"
oauth_client_secret              = "MY_CLIENT_SECRET"
oauth_domain                     = "MY_DOMAIN"
oauth_cookie_secret              = "MY_COOKIE_SECRET"

#---------------------------------------------------------
# Upsource server configuration
#---------------------------------------------------------
upsource_version              = "2017.2.2398"
upsource_root_volume_size_gb  = 8
upsource_ebs_volume_size_gb   = 2
```

NOTE: OAuth values should come from creating a google OAuth Client Account (via [Google Cloud Console](https://console.cloud.google.com)), and the `oauth_cookie_secret` should be a random string of characters to protect browser session cookies.

Run Terraform to create the stack:

```bash
cd terraform
terraform init
terraform apply -var-file vars
```