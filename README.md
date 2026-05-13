# ☁️ 100 Days of Cloud — AWS Challenge

> **Publicly documenting 100 days of hands-on AWS learning — one concept, one lab, one post at a time.**

[![Days Completed](https://img.shields.io/badge/Days%20Completed-23%2F100-blue?style=for-the-badge)](/)
[![Phase](https://img.shields.io/badge/Current%20Phase-Phase%201%3A%20AWS%20Foundations-orange?style=for-the-badge)](/)
[![Platform](https://img.shields.io/badge/Platform-KodeKloud%20%7C%20AWS-yellow?style=for-the-badge)](/)
[![LinkedIn](https://img.shields.io/badge/Follow%20Along-LinkedIn-0A66C2?style=for-the-badge&logo=linkedin)](https://www.linkedin.com/in/venkatesh-gangavarapu)

---

## 🎯 Why I'm Doing This

Cloud infrastructure isn't something you learn by reading — you learn it by breaking things and fixing them. This challenge is my commitment to 100 consecutive days of hands-on AWS work: real labs, real commands, real mistakes documented publicly.

The goal isn't perfection. It's consistency, depth, and building a track record that speaks for itself.

---

## 🗺️ Challenge Roadmap

| Phase | Days | Focus Area | Status |
|-------|------|------------|--------|
| **Phase 1** | 1 – 20 | AWS Foundations (IAM, EC2, VPC, S3, CLI) | ✅ Complete  |
| **Phase 2** | 21 – 40 | Storage, Databases & Networking (RDS, EFS, ELB, Route 53) | 🟡 In Progress |
| **Phase 3** | 41 – 60 | High Availability & Scaling (Auto Scaling, CloudFront, SQS, SNS) | ⬜ Upcoming |
| **Phase 4** | 61 – 80 | DevOps on AWS (CodePipeline, ECS, EKS, CloudFormation, Terraform) | ⬜ Upcoming |
| **Phase 5** | 81 – 100 | Security, Monitoring & Cost Optimization (CloudTrail, GuardDuty, Cost Explorer) | ⬜ Upcoming |

---

## 📅 Daily Log

| Day | Topic | Key Concepts | Status |
|-----|-------|-------------|--------|
| [Day 01](./days/day-01/README.md) | Creating an AWS EC2 Key Pair | Key pair types, .pem permissions, CLI creation, SSH access | ✅ Done |
| [Day 02](./days/day-02/README.md) | Creating an AWS Security Group | Stateful firewall, inbound/outbound rules, SG-as-source, tiered access model | ✅ Done |
| [Day 03](./days/day-03/README.md) | Creating a Subnet in AWS VPC | Public vs private subnets, CIDR planning, route tables, IGW, multi-AZ design | ✅ Done |
| [Day 04](./days/day-04/README.md) | S3 Bucket Versioning | Versioning states, delete markers, version recovery, lifecycle policy pairing | ✅ Done |
| [Day 05](./days/day-05/README.md) | Creating an AWS EBS Volume | gp3 vs gp2, AZ scoping, attach/format/mount lifecycle, snapshots, DLM | ✅ Done |
| [Day 06](./days/day-06/README.md) | Launching an EC2 Instance | AMI resolution, instance types, CPU credits, stop vs terminate, IMDS, user data | ✅ Done |
| [Day 07](./days/day-07/README.md) | Changing EC2 Instance Type | Stop/modify/start lifecycle, status checks, CPU credits, right-sizing strategy | ✅ Done |
| [Day 08](./days/day-08/README.md) | EC2 Stop Protection | DisableApiStop vs DisableApiTermination, limits of protection, IAM controls, audit | ✅ Done |
| [Day 09](./days/day-09/README.md) | EC2 Termination Protection | DisableApiTermination, stop vs terminate distinction, ASG impact, Delete on Termination, audit | ✅ Done |
| [Day 10](./days/day-10/README.md) | Attaching an Elastic IP to EC2 | EIP vs dynamic IP, Allocation vs Association ID, disassociate vs release, failover pattern | ✅ Done |
| [Day 11](./days/day-11/README.md) | Attaching an ENI to EC2 | Primary vs secondary ENIs, AZ constraint, device index, MAC failover, OS config | ✅ Done |
| [Day 12](./days/day-12/README.md) | Attaching an EBS Volume to EC2 | NVMe device naming, AZ constraint, format/mount/fstab lifecycle, nofail, Delete on Termination | ✅ Done |
| [Day 13](./days/day-13/README.md) | Creating an AMI from an EC2 Instance | AMI vs snapshot, no-reboot flag, available state, deregister + cleanup, golden AMI pipeline | ✅ Done |
| [Day 14](./days/day-14/README.md) | Terminating an EC2 Instance | Stop vs terminate, DeleteOnTermination, EIP cleanup, pre-termination checklist, Spot interruptions | ✅ Done |
| [Day 15](./days/day-15/README.md) | Creating an EBS Snapshot | Incremental model, pending vs completed, DLM vs AWS Backup, restore workflow, cross-region copy | ✅ Done |
| [Day 16](./days/day-16/README.md) | Creating an IAM User | IAM user vs role vs group, least privilege, MFA enforcement, credential report, IAM Identity Center | ✅ Done |
| [Day 17](./days/day-17/README.md) | Creating an IAM Group | Groups vs direct attachment, additive permissions, no nesting, group-as-principal limitation, delete order | ✅ Done |
| [Day 18](./days/day-18/README.md) | Creating an IAM Policy | Policy JSON anatomy, ec2:Describe*, evaluation logic, Policy Simulator, permission boundaries | ✅ Done |
| [Day 19](./days/day-19/README.md) | Attaching IAM Policy to IAM User | attach vs put-user-policy, ARN resolution, list-entities-for-policy, 10-policy limit, simulation | ✅ Done |
| [Day 20](./days/day-20/README.md) | Creating an IAM Role for EC2 | Trust policy vs permission policy, Instance Profile, IMDS credential flow, STS AssumeRole | ✅ Done |
| [Day 21](./days/day-21/README.md) | Launch EC2 + Associate Elastic IP | End-to-end compound workflow, Ubuntu AMI resolution, wait synchronisation, EIP lifecycle | ✅ Done |
| [Day 22](./days/day-22/README.md) | SSH Key Injection via EC2 User Data | cloud-init, authorized_keys permissions, PermitRootLogin, StrictHostKeyChecking, SSM alternative | ✅ Done |
| [Day 23](./days/day-23/README.md) | S3 Data Migration: Create Bucket + Sync | s3 sync vs cp, us-east-1 bucket quirk, Block Public Access, dryrun verification, cross-account pattern | ✅ Done |
| Day 24–100 | *(rolling updates)* | — | ⬜ |
---

## 🧰 Lab Environment & Tools

| Tool | Purpose |
|------|---------|
| **AWS Free Tier Account** | Primary cloud environment |
| **AWS CLI v2** | Command-line access and automation |
| **KodeKloud** | Guided labs and challenge platform |
| **Terraform** | Infrastructure as Code (Phase 4+) |
| **VS Code** | Local development and scripting |
| **GitHub** | Version control and public portfolio |

---

## 📂 Repository Structure

```
100-days-cloud-aws/
├── README.md               ← This file (portfolio tracker)
├── day-01/
│   ├── README.md           ← Concepts, steps, commands reference, real-world context
│   └── commands.sh         ← All commands used that day
├── day-02/
│   ├── README.md
│   └── commands.sh
└── ...
```

---

## 🔗 Connect

- 💼 [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu) — daily posts throughout the challenge
- 🐙 [GitHub](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) — all code and documentation

---

*Started: April 2026 | Target Completion: July 2026*
