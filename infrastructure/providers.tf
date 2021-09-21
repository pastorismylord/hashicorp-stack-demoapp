terraform {
  required_version = "~> 1.0"
  backend "remote" {
		organization = "edriosv-org" # org name from step 2.
		workspaces {
		          	name = "infrastructure" # name for your app's state.
		          }
				  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.52"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.4"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 3.1"
    }

    hcp = {
      source  = "hashicorp/hcp"
      version = "~> 0.11"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

provider "hcp" {}
