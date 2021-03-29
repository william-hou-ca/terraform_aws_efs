provider "aws" {
  region = "ca-central-1"
}

provider "random" {
  # Configuration options
}

###########################################################################
#
# Create a efs service.
#
###########################################################################

resource "random_id" "nfs" {
  byte_length = 8
}

resource "aws_efs_file_system" "this" {
  creation_token = "tf-nfs-demo-${random_id.nfs.hex}"

  lifecycle_policy {
    # AFTER_7_DAYS, AFTER_14_DAYS, AFTER_30_DAYS, AFTER_60_DAYS, or AFTER_90_DAYS
    transition_to_ia = "AFTER_30_DAYS"
  }

  # Can be either "generalPurpose" or "maxIO"
  performance_mode = "generalPurpose"

  # Valid values: bursting, provisioned. When using provisioned, also set provisioned_throughput_in_mibps
  throughput_mode = "bursting"
  #provisioned_throughput_in_mibps = 

  # option pour encryption
  encrypted = false
  kms_key_id = null

  tags = {
    Name = "tf-nfs-demo-${random_id.nfs.hex}"
  }
}

###########################################################################
#
# Create mount points for efs.
#
###########################################################################

resource "aws_efs_mount_target" "this" {
  for_each = data.aws_subnet.default_subnets

  file_system_id = aws_efs_file_system.this.id
  subnet_id      = each.value.id

  security_groups = data.aws_security_groups.default_sg.ids
}

###########################################################################
#
# Create a efs access point
# mount example: sudo mount -t efs -o tls,accesspoint=fsap-0ecb9c649bbdc39a2 fs-d4ba9439: /efs-ap
#
###########################################################################

resource "aws_efs_access_point" "test" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = 1001
    gid = 1001
  }

  root_directory {
    path = "/user"
    creation_info {
      owner_gid = 1001
      owner_uid = 1001
      permissions = "0755"
    }
  }

  tags = {
    nfs_id = aws_efs_file_system.this.id
    description = "access point with uid and gid of 1001"
  }
}

###########################################################################
#
# Create a efs system policy
#
###########################################################################

resource "aws_efs_file_system_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Id": "efs-policy-wizard-244d7785-a7b4-4cb3-97e6-361483b1abfd",
    "Statement": [
        {
            "Sid": "efs-statement-332e2306-238c-4e2e-9861-a9813c4ebd1d",
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Action": [
                "elasticfilesystem:*"
            ],
            "Condition": {
                "Bool": {
                    "elasticfilesystem:AccessedViaMountTarget": "true"
                }
            }
        }
    ]
}
POLICY

  depends_on = [aws_instance.web]
}

###########################################################################
#
# Create ec2 instance profile and role.Otherwise efs policy will block mount request
#
###########################################################################

resource "aws_iam_role" "this" {
  name = "efs-test-role"

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

resource "aws_iam_policy" "this" {
  name        = "efs-test-policy"
  description = "A test policy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "elasticfilesystem:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "test-attach" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

resource "aws_iam_instance_profile" "this" {
  name = "efs-test_profile"
  role = aws_iam_role.this.name
}

###########################################################################
#
# Create ec2 instances to mount nfs.
#
###########################################################################

resource "aws_instance" "web" {
  count = 2 #if count = 0, this instance will not be created.

  #required parametres
  ami           = data.aws_ami.amz2.id
  instance_type = "t2.micro"

  #optional parametres
  associate_public_ip_address = true
  key_name = "key-hr123000" #key paire name exists in aws.

  vpc_security_group_ids = data.aws_security_groups.default_sg.ids
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]

  iam_instance_profile = aws_iam_instance_profile.this.name

  tags = {
    Name = "web-${count.index}"
  }

  user_data = <<EOF
            #! /bin/sh
            sudo yum update -y
            sudo amazon-linux-extras install -y nginx1
            sudo yum install -y amazon-efs-utils
            sudo systemctl start nginx
            sudo curl -s http://169.254.169.254/latest/meta-data/local-hostname >/tmp/hostname.html
            sudo mv /tmp/hostname.html /usr/share/nginx/html/index.html
            sudo chmod a+r /usr/share/nginx/html/index.html
            sudo mkdir /usr/share/nginx/html/efs
            sudo mount -t efs ${aws_efs_file_system.this.id}:/ /usr/share/nginx/html/efs
            sudo echo "efs in web-${count.index} is working!!!" >>/usr/share/nginx/html/efs/index.html
            EOF

  # root block device configuration
  /*
  root_block_device {
    delete_on_termination = true
    encrypted = false
    volume_size = 8
    volume_type = "gp2"
  }
  */
  
  #you could add additional disks by using ebs_block_device block. same as root_block_device.
  /*
  ebs_block_device {
    device_name = "web_ebs_device1" #required
    delete_on_termination = true
    encrypted = false
    volume_size = 8
    volume_type = "gp2"
  }
  */

  depends_on = [
    aws_efs_mount_target.this, aws_efs_access_point.test
  ]

}

