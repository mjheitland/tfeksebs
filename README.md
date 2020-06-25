# tfeksebs - build and run Docker image on EKS, add EBS storage

## Intro

The Docker image contains a simple Python Flask web server that returns "hello world!".

This project lists all the steps that are required to 
- build a Docker image
- push this image to ECR
- set up VPC
- deploy an EKS cluster with worker nodes
- run the Docker container in a Kubernetes pod within EKS
- test the web server


## Pre-requisites

* install kubectl on local box:
```
  curl -o kubectl https://amazon-eks.s3-us-west-2.amazonaws.com/1.14.6/2019-08-22/bin/darwin/amd64/kubectl

  chmod +x kubectl

  sudo mv kubectl /usr/local/bin
```
* install flask python library on local box:
```
  pip3 install flask
```
* test Python web app locally:
```
  cd _prerequisites

  python3 app.py

  http://localhost:8080
```
* build docker image and test it:
```  
  docker build . -t pythonhelloworld

  docker run -p 8080:8080 pythonhelloworld
  
  http://localhost:8080
```
* create IAM user "KubernetesAdmin" with admin permissions in AWS console

  and use its access and secret key for TF deployment:
```
  aws configure

  aws sts get-caller-identity
```
* create key pair "IrelandEKS" in eu-west-1 and download the private key file "IrelandEKS.pem"<br>
(use ssh-keygen if you do not have a private key in ~/.ssh/id_rsa)

* create ECR repository, log into ECR, tag image and push it to ECR:
```
  aws ecr create-repository --repository-name pythonhelloworld

  aws ecr get-login-password \
  | docker login \
      --username AWS \
      --password-stdin 094033154904.dkr.ecr.eu-west-1.amazonaws.com

  docker tag pythonhelloworld 094033154904.dkr.ecr.eu-west-1.amazonaws.com/pythonhelloworld

  docker push 094033154904.dkr.ecr.eu-west-1.amazonaws.com/pythonhelloworld
```

## Layer 0 - Terraform Remote State 

Set up remote state for Terraform:<br>
(if you want to save TF state including this layer, run the commands twice and remove the comments for the backend in tfstate.tf on the second run):<br>

```
cd 0_tfstate

terraform init -backend-config=../backend.config

terraform apply -auto-approve

terraform destroy -auto-approve
```

## Layer 1 - Network

The following steps are done automatically if you deploy 1_network with Terraform:

* create a VPC "EKSVPC" with a single public subnet in AZ a using the AWS console wizard

* add another subnet to this VPC with CIDR 10.0.1.0/24 in AZ b

* for second subnet, add route to Internet Gateway: 0.0.0.0/0 => igw

* for both subnets, auto-assign public ip4 address

* add a security group for this VPC with port 443 open for all traffic (0.0.0.0/0) in the new VPC

```
cd 1_network

terraform init -backend-config=../backend.config

terraform apply -auto-approve

(beforehand ELB has to be destroyed manually!)
terraform destroy -auto-approve
```

## Layer 2 - Compute

These steps are done automatically if you deploy 2_compute with Terraform:

* create EKS cluster role "eks_cluster_role" with AmazonEKSClusterPolicy (Trust Relationship set to eks.amazonaws.com)

* create EC2 role "eks_node_role" with AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy and AmazonEC2ContainerRegistryReadOnly policy  (Trust Relationship set to ec2.amazonaws.com)

* create EKS cluster "eksebs" linked to the VPC, subnets, "EKSRole" and security group:<br>
aws eks create-cluster \
   --region eu-west-1 \
   --name eksebs \
   --kubernetes-version 1.16 \
   --role-arn arn:aws:iam::094033154904:role/eks_cluster_role \
   --resources-vpc-config subnetIds=subnet-0efb86813f8213218,subnet-0b75bcf7ea0d4c711,securityGroupIds=sg-0daaf335839a8c338
aws eks describe-cluster ebsEKS

* add EKS worker nodes: set name to "eksebs_nodegroup", set role to eks_node_role, set ssh key to "IrelandEKS" and leave the rest to its defaults

```
cd 2_eks
terraform init -backend-config=../backend.config

terraform apply -auto-approve

terraform destroy -auto-approve
```

## Manual steps to configure kubectl, deploy pod and service and test web server

* configure kubectl:<br>
```
aws eks --region eu-west-1 update-kubeconfig --name eksebs<br>
kubectl get svc<br>
kubectl get nodes
```

* deploy Kubernetes pod:<br>
```
kubectl apply -f deployment.yaml<br>
kubectl get deployment eksebs-deployment -o yaml<br>
kubectl get pods
```

* deploy Kubernetes service (adds an ELB so that we can reach the pod from outside):<br>
```
kubectl apply -f service.yaml<br>
kubectl get service eksebs-service
```

* test the app running on Docker in a Kubernetes cluster in the browser (use the output from the last command):<br>
```
a83db63935a0e4de0ad8460e1971db19-1300743338.eu-west-1.elb.amazonaws.com<br>
```
should return "Hello world!"

* [Add persistent storage to EKS](https://aws.amazon.com/premiumsupport/knowledge-center/eks-persistent-storage/)
