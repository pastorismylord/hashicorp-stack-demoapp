resource "aws_key_pair" "boundary" {
  key_name   = var.name
  public_key = file(local.public_ssh_key_path)

  tags = local.tags
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "worker" {
  count                       = var.num_workers
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  iam_instance_profile        = aws_iam_instance_profile.boundary.name
  subnet_id                   = var.public_subnet_ids[count.index]
  key_name                    = aws_key_pair.boundary.key_name
  vpc_security_group_ids      = [aws_security_group.worker.id]
  associate_public_ip_address = true

  connection {
    type         = "ssh"
    user         = "ubuntu"
    private_key  = base64decode(var.private_ssh_key)
    password     = password
    host         = self.private_ip
    bastion_host = aws_instance.controller[count.index].public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/pki/tls/boundary",
      "echo '${tls_private_key.boundary.private_key_pem}' | sudo tee ${var.tls_key_path}",
      "echo '${tls_self_signed_cert.boundary.cert_pem}' | sudo tee ${var.tls_cert_path}",
    ]
  }

  provisioner "file" {
    source      = "${local.boundary_bin}/boundary"
    destination = "~/boundary"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv ~/boundary /usr/local/bin/boundary",
      "sudo chmod 0755 /usr/local/bin/boundary",
    ]
  }

  provisioner "file" {
    content = templatefile("${path.module}/install/worker.hcl.tpl", {
      controller_ips         = aws_instance.controller.*.private_ip
      name_suffix            = count.index
      public_ip              = self.public_ip
      private_ip             = self.private_ip
      tls_disabled           = var.tls_disabled
      tls_key_path           = var.tls_key_path
      tls_cert_path          = var.tls_cert_path
      kms_type               = var.kms_type
      kms_worker_auth_key_id = aws_kms_key.worker_auth.id
    })
    destination = "~/boundary-worker.hcl"
  }

  provisioner "remote-exec" {
    inline = ["sudo mv ~/boundary-worker.hcl /etc/boundary-worker.hcl"]
  }

  provisioner "file" {
    source      = "${path.module}/install/install.sh"
    destination = "~/install.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod 0755 ~/install.sh",
      "sudo ~/./install.sh worker"
    ]
  }

  tags = merge(local.tags, { Component = "worker" })

  depends_on = [aws_instance.controller]
}


resource "aws_instance" "controller" {
  count                       = var.num_controllers
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  iam_instance_profile        = aws_iam_instance_profile.boundary.name
  subnet_id                   = var.public_subnet_ids[count.index]
  key_name                    = aws_key_pair.boundary.key_name
  vpc_security_group_ids      = [aws_security_group.controller.id]
  associate_public_ip_address = true

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = base64decode(var.private_ssh_key)
    host        = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/pki/tls/boundary",
      "echo '${tls_private_key.boundary.private_key_pem}' | sudo tee ${var.tls_key_path}",
      "echo '${tls_self_signed_cert.boundary.cert_pem}' | sudo tee ${var.tls_cert_path}",
    ]
  }

  provisioner "file" {
    source      = "${local.boundary_bin}/boundary"
    destination = "~/boundary"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv ~/boundary /usr/local/bin/boundary",
      "sudo chmod 0755 /usr/local/bin/boundary",
    ]
  }

  provisioner "file" {
    content = templatefile("${path.module}/install/controller.hcl.tpl", {
      name_suffix            = count.index
      db_endpoint            = aws_db_instance.boundary.endpoint
      private_ip             = self.private_ip
      tls_disabled           = var.tls_disabled
      tls_key_path           = var.tls_key_path
      tls_cert_path          = var.tls_cert_path
      kms_type               = var.kms_type
      kms_worker_auth_key_id = aws_kms_key.worker_auth.id
      kms_recovery_key_id    = aws_kms_key.recovery.id
      kms_root_key_id        = aws_kms_key.root.id
    })
    destination = "~/boundary-controller.hcl"
  }

  provisioner "remote-exec" {
    inline = ["sudo mv ~/boundary-controller.hcl /etc/boundary-controller.hcl"]
  }

  provisioner "file" {
    source      = "${path.module}/install/install.sh"
    destination = "~/install.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod 0755 ~/install.sh",
      "sudo ~/./install.sh controller"
    ]
  }

  tags = merge(local.tags, { Component = "controller" })
}

resource "aws_security_group" "controller" {
  vpc_id = var.vpc_id

  tags = merge(local.tags, { Component = "controller" })
}

resource "aws_security_group_rule" "allow_ssh_controller" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] # Needs to be open for TFC
  security_group_id = aws_security_group.controller.id
}

# Boundary API
resource "aws_security_group_rule" "allow_9200_controller" {
  type                     = "ingress"
  from_port                = 9200
  to_port                  = 9200
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.controller_lb.id
  security_group_id        = aws_security_group.controller.id
}

resource "aws_security_group_rule" "allow_9201_controller" {
  type              = "ingress"
  from_port         = 9201
  to_port           = 9201
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr_block]
  security_group_id = aws_security_group.controller.id
}

resource "aws_security_group_rule" "allow_egress_controller" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.controller.id
}

resource "aws_security_group" "worker" {
  vpc_id = var.vpc_id

  tags = merge(local.tags, { Component = "worker" })
}

resource "aws_security_group_rule" "allow_ssh_worker" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "allow_9202_worker" {
  type              = "ingress"
  from_port         = 9202
  to_port           = 9202
  protocol          = "tcp"
  cidr_blocks       = [var.client_cidr_block]
  security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "allow_egress_worker" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker.id
}