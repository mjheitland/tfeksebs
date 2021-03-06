# tfeksebs - build and run Docker image on EKS, add EBS and EFS storage

## Intro

The Docker image contains a simple Python Flask web server that returns "hello world!".

This project lists all the steps that are required to 
- build a Docker image
- push this image to ECR
- set up VPC
- deploy an EKS cluster with worker nodes
- run the Docker container in a Kubernetes pod within EKS
- test the web server
- use EBS as pod storage
- use EFS as pod storage (share volume btw two pods)


## Pre-requisites

* Install Docker and kubectl: 
For macOS:
```
https://matthewpalmer.net/kubernetes-app-developer/articles/guide-install-kubernetes-mac.html 
```
* Deploy the Metrics Server with the following command:
```
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.3.7/components.yaml 
```
* Verify that the metrics-server deployment is running the desired number of pods with the following command.
[Installing the Kubernetes Metrics Server](https://docs.aws.amazon.com/eks/latest/userguide/metrics-server.html)
```
kubectl get deployment metrics-server -n kube-system
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
* build docker image and test it locally (inside Docker Desktop):
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

  aws ecr get-login-password --region eu-west-1 \
  | docker login \
      --username AWS \
      --password-stdin 094033154904.dkr.ecr.eu-west-1.amazonaws.com

  docker tag pythonhelloworld 094033154904.dkr.ecr.eu-west-1.amazonaws.com/pythonhelloworld

  docker push 094033154904.dkr.ecr.eu-west-1.amazonaws.com/pythonhelloworld
```

## Layer 0 - Terraform Remote State (2 min)

Set up remote state for Terraform creating a bucket for the state and a DynamoDB table for locking<br>
(if you want to save TF state including this layer, run the commands twice and remove the comments for the backend in tfstate.tf on the second run)

Terraform code:
```
cd 0_tfstate

terraform init -backend-config=../backend.config

terraform apply -auto-approve

cd ..

# terraform destroy -auto-approve
```

## Layer 1 - Network (5 min)

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

cd ..

# (beforehand ELB and EC2 volumes have to be destroyed manually, they were created later by Kubernetes, not by Terraform!)
# terraform destroy -auto-approve
```

## Layer 2 - Compute (15 min)

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

Terraform code (apply takes 15 min for EKS cluster plus 5 min for EKS Cluster Node Group, VPN does not cause any issues during deployment):
```
cd 2_compute

terraform init -backend-config=../backend.config

terraform apply -auto-approve

# terraform destroy -auto-approve
```


## Manual steps to configure kubectl to point to our new EKS

* configure kubectl:
```
aws eks --region eu-west-1 update-kubeconfig --name eksebs
kubectl get svc
kubectl get nodes
```


## Manual steps to mount EBS volume to EKS pod "app" ("app" is automatically writing logs to /data/out.txt)

* deploy the Amazon EBS CSI Driver, create a storage class (SC), a persistent volume (PV) and a persistent volume claim (PVC):<br>
[see "Add persistent storage to EKS"](https://aws.amazon.com/premiumsupport/knowledge-center/eks-persistent-storage/)
```
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"

kubectl apply -f ebs/

sleep 10

kubectl get persistentvolumes
```
The kubectl command creates a StorageClass, PersistentVolumeClaim (PVC), and pod. The pod references the PVC. An Amazon EBS volume is provisioned only when the pod is created.

*  to verify that the pod is successfully writing data to the volume, run the following command:
```
kubectl exec -it app cat /data/out.txt
```


## Manual steps to mount EFS volume to EKS pods (pod "app1" is automatically writing logs to /data/out1.txt, pod "app2" is automatically writing logs to /data/out2.txt, every pod can see both files in /data)

* deploy the Amazon EFS CSI Driver, run the following command:<br>
[see "Add persistent storage to EKS"](https://aws.amazon.com/premiumsupport/knowledge-center/eks-persistent-storage/)
```
kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
```

* in efs/pv.yaml, set "volumehandle" to Terraform's output value from 2_compute 'efs_id' (e.g. volumeHandle: fs-8c59eb46)

* test EFS access from two different pods (out1.txt was created by app1, out2.txt by app2):
```
kubectl apply -f efs/

kubectl get pods

kubectl get persistentvolumes

kubectl exec -it app1 -- tail /data/out1.txt 
kubectl exec -it app1 -- tail /data/out2.txt 

kubectl exec -it app2 -- tail /data/out1.txt
kubectl exec -it app2 -- tail /data/out2.txt 
```


## Manual steps to deploy Kubernetes service, test web app running on Docker container and access EFS share

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

* wait a while, then open a browser and test the app running on Docker in a Kubernetes cluster (use the ELB arn output from the last command - EXTERNAL_IP):
```
xxx.eu-west-1.elb.amazonaws.com
```
should return "Hello world!"

* test access to EFS share
```
kubectl get pods
kubectl exec -it eksebs-deployment-eksebs-deployment-xxx sh
cd /data
ls
# you should see two files: out1.txt and out2.txt
exit
```

## Links

[Checking out Auto-Scaling](https://docs.aws.amazon.com/eks/latest/userguide/cluster-autoscaler.html)

[Amazon EKS Troubleshooting](https://docs.aws.amazon.com/eks/latest/userguide/troubleshooting.html)

[Capacity-Optimized Spot Instance Allocation](https://aws.amazon.com/blogs/aws/capacity-optimized-spot-instance-allocation-in-action-at-mobileye-and-skyscanner/?sc_campaign=pac_cia_2020_blog_capacity-optimized&sc_channel=el&sc_geo=mult&sc_icampaign=pac_cia_2020_blog_capacity-optimized&sc_ichannel=ha&sc_icontent=awssm-3771&sc_iplace=console-ec2autoscaling&sc_outcome=Enterprise_Digital_Marketing&trk=el_a134p000006C2hLAAS~ha_awssm-3771&trkCampaign=pac-edm-2020-ec2_blog-capacity-optimized)

[Running a Kubernetes cluster on EKS with Fargate and Terraform](https://engineering.finleap.com/posts/2020-02-27-eks-fargate-terraform/)

[EKS Fargate with Terraform - Source code](https://github.com/finleap/tf-eks-fargate-tmpl)

[AWS Fargate User Guide](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)