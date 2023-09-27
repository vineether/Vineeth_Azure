
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = ">=2.0"
    }
  }
}


provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "my-resource" {
  name     =  "my-resource"
  location =  "East US"
}
resource "azurerm_virtual_network" "my-vnet" {
  name                = "my-vnet"
  address_space       = ["172.33.0.0/16"]
  location            = "East US"
  resource_group_name = azurerm_resource_group.my-resource.name
}

resource "azurerm_subnet" "dmz" {
  name                 = "dmz-subnet"
  resource_group_name  = azurerm_resource_group.my-resource.name
  virtual_network_name = azurerm_virtual_network.my-vnet.name
  address_prefixes     = ["172.33.1.0/24"]
}

resource "azurerm_subnet" "data" {
  name                 = "data-subnet"
  resource_group_name  = azurerm_resource_group.my-resource.name
  virtual_network_name = azurerm_virtual_network.my-vnet.name
  address_prefixes     = ["172.33.2.0/24"]
}

resource "azurerm_subnet" "compute" {
  name                 = "compute-subnet"
  resource_group_name  = azurerm_resource_group.my-resource.name
  virtual_network_name = azurerm_virtual_network.my-vnet.name
  address_prefixes     = ["172.33.3.0/24"]
}

# Create a security group with SSH rule
resource "azurerm_network_security_group" "my-nsg" {
  name                = "my-nsg"
  location            = "East US"
  resource_group_name = azurerm_resource_group.my-resource.name
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = var.ssh_port
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# # Create a public IP address
resource "azurerm_public_ip" "pub-ip" {
  name                = "pub-pip"
  location            = "East US"
  resource_group_name = azurerm_resource_group.my-resource.name
  allocation_method   = "Dynamic" 
  sku   = "Basic"
}

# # Create a network interface with the security group
resource "azurerm_network_interface" "pub-nic" {
  name                = "pub-nic"
  location            = "East US"
  resource_group_name = azurerm_resource_group.my-resource.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.compute.id
    private_ip_address_allocation = "Dynamic"
  }
}

# # Create a virtual machine
resource "azurerm_virtual_machine" "my-vm" {
  name                  = "my-vm"
  location              = "East US"
  resource_group_name   = azurerm_resource_group.my-resource.name
  network_interface_ids = [azurerm_network_interface.pub-nic.id]

  vm_size              = "Standard_DS2_v2"
  delete_os_disk_on_termination = true

  storage_os_disk {
    name              = "${var.vm_name}-osdisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    os_type           = "Linux"
  }

  os_profile {
    computer_name = "my-vm"
    admin_username = "admin"
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y apache2",
      "sudo rm /var/html/index.html",
      "sudo touch /var/html/index.html",
      "echo <html><h1>hello world<h1></html> > /var/html/index.html"]
  }

  connection {
    type        = "ssh"
    user        = "adminuser"
    private_key = file("~/.ssh/id_rsa")  # Path to your SSH private key
    host        = azurerm_public_ip.pub-ip.ip_address
  }
}

# Create a Load Balancer
resource "azurerm_lb" "my-lb" {
  name                = "my-lb"
  resource_group_name = azurerm_resource_group.my-resource.name
  location            = "East US"
  sku                 = "Basic"

  frontend_ip_configuration {
    name                 = "my-lb-feipconfig"
    public_ip_address_id = azurerm_public_ip.pub-ip.id
  }
}

# Create a backend pool for the Load Balancer
resource "azurerm_lb_backend_address_pool" "my-backend" {
  name                = "my-backend"
  loadbalancer_id     = azurerm_lb.my-lb.id
}
# Create a Load Balancer rule with "Source IP Affinity" algorithm
resource "azurerm_lb_rule" "lb-rule" {
  name                   = "lb-rule"
#   resource_group_name    =  azurerm_resource_group.my-resource
  loadbalancer_id        = azurerm_lb.my-lb.id
  frontend_ip_configuration_name = azurerm_lb.my-lb.frontend_ip_configuration[0].name
  backend_address_pool_ids = [azurerm_lb_backend_address_pool.my-backend.id]
  protocol               = "Tcp"
  frontend_port          = 80
  backend_port           = 80
  enable_floating_ip     = false
  idle_timeout_in_minutes = 5
  load_distribution      = "SourceIP"
}


resource "azurerm_network_interface_backend_address_pool_association" "backend-association" {
  network_interface_id    = azurerm_network_interface.pub-nic.id
  ip_configuration_name   = azurerm_network_interface.pub-nic.ip_configuration[0].name
  backend_address_pool_id = azurerm_lb_backend_address_pool.my-backend.id
}

# Configure the Azure Monitor Autoscale settings
resource "azurerm_monitor_autoscale_setting" "my-autoscale" {
  name                = "my-autoscale"
  resource_group_name = azurerm_resource_group.my-resource.name
  location            = azurerm_resource_group.my-resource.location
  target_resource_id  = azurerm_virtual_machine.my-vm.id

  profile {
    name = "defaultProfile"

    capacity {
      default = 2
      minimum = 2
      maximum = 5
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_virtual_machine.my-vm.id
        time_aggregation   = "Average"
        time_grain = "PT1M"
        statistic          = "Average"
        operator           = "GreaterThan"
        threshold          = 75  # Adjust the threshold as needed
        time_window        = "PT5M"  # Evaluation window
      }
        # scale_in_trigger  {
        #   direction = "Decrease"
        #   type      = "ChangeCount"
        #   change_count = 1
        #   cooldown    = "PT5M"
        # }

    #     scale_out_trigger {
    #       direction = "Increase"
    #       type      = "ChangeCount"
    #       change_count = 1
    #       cooldown    = "PT5M"
    #     }
    #    }

      scale_action {
        direction = "Decrease"
        type = "ChangeCount"
        value = "1"
        cooldown = "PT1M"
         }
 }
 }
}

resource "azurerm_storage_account" "myaccount" {
  name                     = "myaccount"
  resource_group_name      = azurerm_resource_group.my-resource.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  enable_https_traffic_only = true
#   availability_zone        = "1"
}

# Create a Blob Container within the Storage Account
resource "azurerm_storage_container" "storage-container" {
  name                  = "storage-container"
  storage_account_name  = azurerm_storage_account.myaccount.name
  container_access_type = "private" # You can adjust this based on your access requirements
}

# Output the connection string for the Storage Account
output "storage_account_connection_string" {
  value = azurerm_storage_account.myaccount.primary_connection_string
  sensitive = true
}


# Generate a SAS token for read-only access
resource "azurerm_storage_account_sas" "sas" {
  connection_string = data.azurerm_storage_account.my-account.primary_connection_string
  start             = "2023-01-01"
  expiry            = formatdate("YYYY-MM-DDTHH:MM:SSZ", timeadd(timestamp(), "168h")) # 7 days from now
  resource_types    = "co"
  services          = "bfqt"
  permissions       = "r"
}

resource "azurerm_role_assignment" "role" {
  principal_id       = "0a4c7907-7c55-4ab8-b95f-b9ed01d81dcf"
  role_definition_name = "Storage Blob Data Reader"
  scope     =   azurerm_resource_group.my-resource.name
}