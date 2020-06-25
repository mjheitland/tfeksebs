#--- 1_network/config.tf ---

terraform {
  required_version = ">= 0.12"
  required_providers {
    aws = ">= 2.61.0"
  }
  backend "s3" {
    key = "1_network.tfstate"
  }
}

provider "aws" {
  region = var.region
  profile = "default"
}
