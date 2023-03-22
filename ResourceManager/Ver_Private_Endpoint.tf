variable "region" {}
variable "compartment_ocid" {}
variable "subnet_ocid" {} // Subred privada que esta en la instancia
variable "tenancy_ocid" {} // VCN que contiene la subred privada

// Punto final privado que ya se ha creado.
variable "orm_private_endpoint_ocid" {
  type = string
}

provider "oci" {
  region = "${var.region}"
}

// Variables locales definidas para aumentar la legibilidad.
// La unica variable local que debe permanecer consistente es tcp_protocol, ya que especifica que se usara para SSH
locals {
  tcp_protocol = 6
  default_shape_name = "VM.Standard.E3.Flex"
  operating_system = "Oracle Linux"
}

data "oci_identity_availability_domains" "get_availability_domains" {
  compartment_id = var.tenancy_ocid
}


data "oci_core_images" "available_instance_images" {
  compartment_id = var.compartment_ocid
  operating_system = local.operating_system
  shape = local.default_shape_name
}

// Use una fuente de datos para obtener un punto final privado preexistente. Este punto final privado ya podría crearse a través de CLI, SDK, consola, etc.
// en su tenance
data "oci_resourcemanager_private_endpoint" "get_private_endpoint" {
  private_endpoint_id = var.orm_private_endpoint_ocid
}

// Resuelve la IP privada del extremo privado del cliente en una IP NAT. Se utiliza como dirección de host en el recurso "remote-exec"
data "oci_resourcemanager_private_endpoint_reachable_ip" "test_private_endpoint_reachable_ips" {
  private_endpoint_id = data.oci_resourcemanager_private_endpoint.get_private_endpoint.id
  private_ip          = oci_core_instance.private_endpoint_instance.private_ip
}

// La clave pública/privada utilizada para SSH a la instancia 
resource "tls_private_key" "public_private_key_pair" {
  algorithm = "RSA"
}

// El extremo privado permitirá la comunicación SSH para
resource "oci_core_instance" "private_endpoint_instance" {
  compartment_id = var.compartment_ocid
  display_name = "test script as one remote-exec instance"

  availability_domain = lookup(data.oci_identity_availability_domains.get_availability_domains.availability_domains[0], "name")
  shape = local.default_shape_name

  // specify this is a private by not assigning public ip
  create_vnic_details {
    subnet_id = var.subnet_ocid
    assign_public_ip = false
  }

  extended_metadata = {
    ssh_authorized_keys = tls_private_key.public_private_key_pair.public_key_openssh
  }

  source_details {
    source_id = data.oci_core_images.available_instance_images.images[0].id
    source_type = "image"
  }

  shape_config {
    memory_in_gbs = 4
    ocpus = 1
  }
}

// Recurso para establecer la conexión SSH. Debe tener la instancia creada primero.
resource "null_resource" "remote-exec" {
  depends_on = [oci_core_instance.private_endpoint_instance]

  provisioner "remote-exec" {
    connection {
      agent = false
      timeout = "30m"
      host = data.oci_resourcemanager_private_endpoint_reachable_ip.test_private_endpoint_reachable_ips.ip_address
      user = "opc"
      private_key = tls_private_key.public_private_key_pair.private_key_pem
    }
    // write to a file on the compute instance via the private access SSH connection
    inline = [
      "echo 'remote exec showcase' > ~/remoteExecTest.txt"
    ]
  }
}