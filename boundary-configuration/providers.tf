terraform {
  required_version = "~> 1.0"
  backend "remote" {
		organization = "EdV" # org name from step 2.
		workspaces {
		          	name = "boundary-configuration" # name for your app's state.
		          }
				  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.52"
    }
    boundary = {
      source  = "hashicorp/boundary"
      version = "~> 1.0"
    }
  }
}

provider "aws" {
  region = local.region
}

provider "boundary" {
  addr             = local.url
  recovery_kms_hcl = <<EOT
kms "awskms" {
	purpose    = "recovery"
  region = "${local.region}"
	key_id     = "global_root"
  kms_key_id = "${local.kms_recovery_key_id}"
}
EOT
}
