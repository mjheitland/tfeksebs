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

Set up remote state for Terraform creating a bucket for the state and a DynamoDB table for locking<br>
(if you want to save TF state including this layer, run the commands twice and remove the comments for the backend in tfstate.tf on the second run)

Terraform code:
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

* add a security group for this VPC with port 443 (https) and 2049 (EFS) open for all traffic (0.0.0.0/0) in the new VPC


Terraform code:
```
cd 1_network

terraform init -backend-config=../backend.config

terraform apply -auto-approve

(beforehand ELB has to be destroyed manually!)
terraform destroy -auto-approve
```

## Layer 2 - Compute

These steps are done automatically if you deploy 2_compute with Terraform:

* create a key pair "IrelandEKS" in eu-west-1 and download the private key file "IrelandEKS.pem"<br>
(with Terraform: use ssh-keygen if you do not have a private key in ~/.ssh/id_rsa)

* create EKS cluster role "eks_cluster_role" with AmazonEKSClusterPolicy (Trust Relationship set to eks.amazonaws.com)

* create EC2 role "eks_node_role" with AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy and AmazonEC2ContainerRegistryReadOnly policy and a policy to work with EBS volumes (Trust Relationship set to ec2.amazonaws.com)

* create EKS cluster "eksebs" linked to the VPC, subnets, "EKSRole" and security group:
```
aws eks create-cluster \
   --region eu-west-1 \
   --name eksebs \
   --kubernetes-version 1.16 \
   --role-arn arn:aws:iam::094033154904:role/eks_cluster_role \
   --resources-vpc-config subnetIds=subnet-0efb86813f8213218,subnet-0b75bcf7ea0d4c711,securityGroupIds=sg-0daaf335839a8c338
aws eks describe-cluster ebsEKS
```

* add EKS worker nodes: set name to "eksebs_nodegroup", set role to eks_node_role, set ssh key to "IrelandEKS" and leave the rest to its defaults (takes about 15 minutes)

* create EFS network share

Terraform code:
```
cd 2_eks
terraform init -backend-config=../backend.config

terraform apply -auto-approve

terraform destroy -auto-approve
```

## Manual steps to configure kubectl, deploy pod and service and test web server

* configure kubectl:
```
aws eks --region eu-west-1 update-kubeconfig --name eksebs
kubectl get svc
kubectl get nodes
```

* deploy the Amazon EFS CSI Driver, run the following command:<br>
[see "Add persistent storage to EKS"](https://aws.amazon.com/premiumsupport/knowledge-center/eks-persistent-storage/)
```
kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
kubectl apply -f efs/
kubectl get persistentvolumes
```

* set "volumehandle" to output value efs_id in efs/pv.yaml

* test EFS access from two different pods
```
kubectl apply -f efs/
kubectl exec -it app1 -- tail /data/out1.txt 
kubectl exec -it app2 -- tail /data/out1.txt
```

* deploy the Amazon EBS CSI Driver, create a storage class (SC), a persistent volume (PV) and a persistent volume claim (PVC):<br>
[see "Add persistent storage to EKS"](https://aws.amazon.com/premiumsupport/knowledge-center/eks-persistent-storage/)
```
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
kubectl apply -f ebs/
kubectl get persistentvolumes
```
The kubectl command creates a StorageClass, PersistentVolumeClaim (PVC), and pod. The pod references the PVC. An Amazon EBS volume is provisioned only when the pod is created.

* deploy Kubernetes pod:
```
kubectl apply -f deployment.yaml
kubectl get deployment eksebs-deployment -o yaml
kubectl get pods
```

* deploy Kubernetes service (adds an ELB so that we can reach the pod from outside):
```
kubectl apply -f service.yaml
kubectl get service eksebs-service
```

* test the app running on Docker in a Kubernetes cluster in the browser (use the ELB arn output from the last command):
```
xxx.eu-west-1.elb.amazonaws.com
```
should return "Hello world!"
