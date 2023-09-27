variable "my-resource" {

  description = "Name of the Azure resource group"
  type        = string
}
variable "my-vnet" {
  description = "Name of the Vnet"
  type        = string
}


variable "location" {
  description = "Azure region"
  type        = string
  default     = "East US"
}

variable "vm_name" {
  description = "Name of the virtual machine"
  type        = string
}

# Define the SSH port (Port 22) in the security group rule
variable "ssh_port" {
  description = "SSH Port"
  type        = number
  default     = 22
}

variable "my-lb" {
  description = "Name of the Azure Load Balancer"
  type        = string
}
