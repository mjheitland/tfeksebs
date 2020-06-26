#-- 2_compute/compute.tf ---

#------------------
#--- Data Providers
#------------------

data "terraform_remote_state" "tf_network" {
  backend = "s3"
  config = {
    bucket = var.bucket
    key = "1_network.tfstate"
    region = var.region
  }
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*"]
  }
  filter {
      name   = "root-device-type"
      values = ["ebs"]
    }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }  
}  


#-------------
#--- Variables
#-------------

variable "project" {
  description = "project name is used as resource tag"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable bucket {
  description = "S3 bucket to store TF remote state"
  type        = string
}

variable "key_name" {
  description = "name of keypair to access ec2 instances"
  type        = string
  default     = "IrelandEKS"
}

variable "public_key_path" {
  description = "file path on deployment machine to public rsa key to access ec2 instances"
  type        = string
}

variable "cluster_name" {
  default = "eksebs"
  type    = string
}

variable "nodegroup_name" {
  default = "eksebsng"
  type    = string
}

variable "cluster_endpoint_private_access_cidrs" {
  description = "List of CIDR blocks which can access the Amazon EKS private API server endpoint, when public access is disabled"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_endpoint_private_access" {
  description = "Indicates whether or not the Amazon EKS private API server endpoint is enabled."
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks which can access the Amazon EKS public API server endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_endpoint_public_access" {
  description = "Indicates whether or not the Amazon EKS public API server endpoint is enabled."
  type        = bool
  default     = true
}


variable "cluster_create_timeout" {
  description = "Timeout value when creating the EKS cluster."
  type        = string
  default     = "30m"
}

variable "cluster_delete_timeout" {
  description = "Timeout value when deleting the EKS cluster."
  type        = string
  default     = "15m"
}


#---------------------
#--- Role and Policies
#---------------------

#--- eks_cluster_role

resource "aws_iam_role" "eks_cluster_role" {
  name = "eks_cluster_role"
  assume_role_policy = <<EOF
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Principal":{
        "Service":"eks.amazonaws.com"
      },
      "Action":"sts:AssumeRole",
      "Effect":"Allow"
    }
  ]
}
EOF
  tags = {
      Name = format("%s_eks_cluster_role", var.project)
      project = var.project
  }
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.id
}
 
#--- eks_node_role

resource "aws_iam_role" "eks_node_role" {
  name = "eks_node_role"
  assume_role_policy = <<EOF
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Principal":{
        "Service":"ec2.amazonaws.com"
      },
      "Action":"sts:AssumeRole",
      "Effect":"Allow"
    }
  ]
}
EOF
  tags = {
      Name = format("%s_eks_node_role", var.project)
      project = var.project
  }
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.id
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.id
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.id
}

resource "aws_iam_role_policy" "Amazon_EBS_CSI_Driver_Policy" {
  name   = "Amazon_EBS_CSI_Driver_Policy"
  role   = aws_iam_role.eks_node_role.id
  policy = <<POLICY
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AttachVolume",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteSnapshot",
        "ec2:DeleteTags",
        "ec2:DeleteVolume",
        "ec2:DescribeInstances",
        "ec2:DescribeSnapshots",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DetachVolume"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
}


#-----------
#--- Cluster
#-----------

resource "aws_cloudwatch_log_group" "eks_cw_loggroup" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 7
  # ... potentially other configuration ...
}

# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/cluster.tf 
# https://www.terraform.io/docs/providers/aws/r/eks_cluster.html 
resource "aws_eks_cluster" "eks_cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version = "1.16"
  enabled_cluster_log_types = [
    "api", 
    "audit"
  ]
  
  vpc_config {
    security_group_ids      = [data.terraform_remote_state.tf_network.outputs.sgpub1_id]
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
    subnet_ids              = [
      data.terraform_remote_state.tf_network.outputs.subpub1_id,
      data.terraform_remote_state.tf_network.outputs.subpub2_id
    ]
  }

  timeouts {
    create = var.cluster_create_timeout
    delete = var.cluster_delete_timeout
  }

  tags = {
      Name = format("%s_%s", var.project, var.cluster_name)
      project = var.project
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_cloudwatch_log_group.eks_cw_loggroup,
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy
  ]  
}


#----------
#--- Worker
#----------

resource "aws_key_pair" "keypair" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/workers.tf
# https://www.terraform.io/docs/providers/aws/r/eks_node_group.html
resource "aws_eks_node_group" "eks_cluster_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = var.nodegroup_name
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [
    data.terraform_remote_state.tf_network.outputs.subpub1_id,
    data.terraform_remote_state.tf_network.outputs.subpub2_id
  ]

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  remote_access {
    ec2_ssh_key = aws_key_pair.keypair.id
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]
}


#-------
#--- EFS
#-------

resource "aws_efs_file_system" "efs" {
  creation_token = format("%s_%s", var.project, "efs")

  tags = {
    Name = format("%s_%s", var.project, "efs")
    project = var.project
  }
}

resource "aws_efs_mount_target" "efs_mounttarget_1" {
  file_system_id = aws_efs_file_system.efs.id
  subnet_id      = data.terraform_remote_state.tf_network.outputs.subpub1_id
}

resource "aws_efs_mount_target" "efs_mounttarget_2" {
  file_system_id = aws_efs_file_system.efs.id
  subnet_id      = data.terraform_remote_state.tf_network.outputs.subpub2_id
}


#-----------
#--- Outputs
#-----------

output "keypair_id" {
  value = aws_key_pair.keypair.id
}

output "eks_cluster_role_id" {
  value = aws_iam_role.eks_cluster_role.id
}
output "eks_node_role_id" {
  value = aws_iam_role.eks_node_role.id
}
output "eks_cluster_id" {
  value = aws_eks_cluster.eks_cluster.id
}
output "eks_cluster_arn" {
  value = aws_eks_cluster.eks_cluster.arn
}
output "eks_cluster_version" {
  value = aws_eks_cluster.eks_cluster.version
}

output "efs_id" {
  value = aws_efs_file_system.efs.id
}
output "efs_arn" {
  value = aws_efs_file_system.efs.arn
}
output "efs_dns_name" {
  value = aws_efs_file_system.efs.dns_name
}
