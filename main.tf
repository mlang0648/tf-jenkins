provider "aws" {
  region                  = "us-west-2"
  shared_credentials_file = "/Users/mlang0648/.aws/credentials"
  profile                 = "default"
}

# VPC ----------------
module "vpc" {
#    source = "../modules/tf_aws_vpc"
    source = "github.com/terraform-community-modules/tf_aws_vpc"
    name = "ecs-vpc"
    cidr = "10.0.0.0/22"
    public_subnets  = ["10.0.0.0/26","10.0.0.64/26"]
    private_subnets = ["10.0.1.0/26","10.0.1.64/26"]
    azs = ["us-west-2a","us-west-2b"]
    enable_dns_support = true
    enable_dns_hostnames = true
    enable_nat_gateway = true
    tags {
      Name = "tf-jenkins-vpc"
    }
}
# End VPC ------------------

# Bsation Host -------------------------
resource "aws_instance" "bastion_host" {
  ami           = "ami-f173cc91"
  instance_type = "t2.micro"
  subnet_id     = "${module.vpc.public_subnets[0]}"
  associate_public_ip_address = true
  security_groups = ["${aws_security_group.allow_all_ssh.id}","${aws_security_group.allow_all_outbound.id}"]
  key_name = "tf-dev-account"
  tags {
    Name = "bastion-host"
  }
}
# End Bastion Host-----------------------------

# Security Groups-----------------------------------
resource "aws_security_group" "allow_all_ssh" {
    name_prefix = "${module.vpc.vpc_id}-"
    description = "Allow all inbound SSH traffic"
    vpc_id = "${module.vpc.vpc_id}"

    ingress = {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress = {
        from_port = 30000
        to_port = 65535
        protocol = "tcp"
        self = true
    }
    tags {
      Name = "tf-ssh-access-sg"
    }
}

resource "aws_security_group" "allow_all_outbound" {
    name_prefix = "${module.vpc.vpc_id}-"
    description = "Allow all outbound traffic"
    vpc_id = "${module.vpc.vpc_id}"

    egress = {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags {
      Name = "tf-all-outbound-access-sg"
    }
}

resource "aws_security_group" "allow_elb_inbound" {
    name_prefix = "${module.vpc.vpc_id}-"
    description = "Allow all elb inbound traffic"
    vpc_id = "${module.vpc.vpc_id}"

    ingress = {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags {
      Name = "tf-elb-inbound-access-sg"
    }
}

resource "aws_security_group" "allow_jenkins" {
    name_prefix = "${module.vpc.vpc_id}-"
    description = "Allow all traffic within cluster"
    vpc_id = "${module.vpc.vpc_id}"

    ingress = {
        from_port = 0
        to_port = 65535
        protocol = "tcp"
        self = true
    }
    ingress = {
        from_port = 8080
        to_port = 8080
        protocol = "tcp"
        cidr_blocks = ["10.0.0.0/23"]
    }
    ingress = {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["10.0.0.0/23"]
    }
    egress = {
        from_port = 0
        to_port = 65535
        protocol = "tcp"
        self = true
    }
    tags {
      Name = "tf-allow-jenkins-access-sg"
    }
}
#End Security Groups--------------------

# Nat Gateway ---------------------------------------
resource "aws_eip" "nip" {
  vpc      = true
}

resource "aws_nat_gateway" "ngw" {
  allocation_id = "${aws_eip.nip.id}"
  subnet_id     = "${module.vpc.public_subnets[0]}"
  depends_on    = ["aws_eip.nip"]
}

resource "aws_route" "natroute1" {
  route_table_id            = "${module.vpc.private_route_table_ids[0]}"
  destination_cidr_block    = "0.0.0.0/0"
  nat_gateway_id            = "${aws_nat_gateway.ngw.id}"
  depends_on                = ["aws_nat_gateway.ngw"]
}

resource "aws_route" "natroute2" {
  route_table_id            = "${module.vpc.private_route_table_ids[1]}"
  destination_cidr_block    = "0.0.0.0/0"
  nat_gateway_id            = "${aws_nat_gateway.ngw.id}"
  depends_on                = ["aws_nat_gateway.ngw"]
}
#END Nat Gateway--------------------------------

# Jenknins ELB----------------------------------
resource "aws_elb" "jenkins_elb" {
    name = "jenkins-elb"
#    subnets = ["${split(",", module.vpc.public_subnets)}"]
    subnets = ["${module.vpc.public_subnets}"]
    connection_draining = true
    cross_zone_load_balancing = true
    security_groups = [
        "${aws_security_group.allow_jenkins.id}",
        "${aws_security_group.allow_elb_inbound.id}",
        "${aws_security_group.allow_all_outbound.id}"
    ]

    listener {
        instance_port = 8080
        instance_protocol = "http"
        lb_port = 80
        lb_protocol = "http"
    }

    health_check {
        healthy_threshold = 2
        unhealthy_threshold = 10
        target = "tcp:22"
        interval = 5
        timeout = 4
    }
}
#END Jenknins ELB----------------------------------

# Jenkins autoscaling--------------------------------------
resource "aws_launch_configuration" "jenkins_lc" {
    name = "jenkins_lc"
    instance_type = "t2.micro"
    image_id = "ami-8ca83fec"
    iam_instance_profile = "${aws_iam_instance_profile.tf-jenkins-profile.id}"
    security_groups = [
        "${aws_security_group.allow_all_ssh.id}",
        "${aws_security_group.allow_all_outbound.id}",
        "${aws_security_group.allow_jenkins.id}",
    ]
    user_data = "${file("./templates/user_data")}"
    lifecycle {
      create_before_destroy = true
    }
#    key_name = "${aws_key_pair.root.key_name}"
     key_name = "tf-dev-account"
}

resource "aws_autoscaling_group" "jenkins_asg" {
    name = "jenkins_cluster"
    vpc_zone_identifier = ["${module.vpc.private_subnets}"]
    min_size = 1
    max_size = 1
    desired_capacity = 1
    launch_configuration = "${aws_launch_configuration.jenkins_lc.name}"
    load_balancers = ["${aws_elb.jenkins_elb.id}"]
    health_check_type = "EC2"
}
#Jenkins autoscaling-------------------------------------





# IAM Roles and Policies-----------------

/*resource "aws_iam_role" "tf-jenkins-role" {
    name = "tf-jenkins-role"
}*/



resource "aws_iam_role_policy" "s3_policy" {
  name = "s3_policy"
  role = "${aws_iam_role.tf-jenkins-role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}





resource "aws_iam_instance_profile" "tf-jenkins-profile" {
    name = "tf-jenkins-profile"
    roles = ["${aws_iam_role.tf-jenkins-role.name}"]
}

resource "aws_iam_role" "tf-jenkins-role" {
    name = "tf-jenkins-role"
    assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}
#End IAM Roles and Policies----------------------

output "Bastion Host IP" {
  value = "${aws_instance.bastion_host.public_ip}"
}

output "DNS for ELB" {
  value = "${aws_elb.jenkins_elb.dns_name}"
}

output "ELB Instances" {
  value = "${aws_elb.jenkins_elb.instances}"
}
