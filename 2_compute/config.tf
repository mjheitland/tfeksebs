#--- 2_compute/config.tf ---

terraform {
  required_version = ">= 0.12"
  required_providers {
    aws = ">= 2.61.0"
  }
  backend "s3" {
    key = "2_compute.tfstate"
  }
}

provider "aws" {
  region = var.region
  profile = "default"
}
