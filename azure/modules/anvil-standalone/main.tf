# ============================================================
# Single-node (Standalone) Anvil on Azure - the ARM template's
# anvilConfiguration=Standalone path: one data NIC, boot disk +
# one metadata disk (lun 1), custom data with ha_mode Standalone.
# ============================================================

resource "azurerm_public_ip" "anvil" {
  count = var.public_ip ? 1 : 0

  name                = "${var.prefix}Anvil1PubIP"
  location            = var.location
  resource_group_name = var.resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "data" {
  name                = "${var.prefix}Anvil1DataIface"
  location            = var.location
  resource_group_name = var.resource_group
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    primary                       = true
    subnet_id                     = var.data_subnet_id
    private_ip_address_allocation = var.static_ip != "" ? "Static" : "Dynamic"
    private_ip_address            = var.static_ip != "" ? var.static_ip : null
    public_ip_address_id          = var.public_ip ? azurerm_public_ip.anvil[0].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "data" {
  network_interface_id      = azurerm_network_interface.data.id
  network_security_group_id = var.nsg_id
}

# ARM anvilCustomData (verbatim structure).
locals {
  custom_data = jsonencode({
    cluster = {
      domainname = var.domain
    }
    node = {
      hostname = "${var.prefix}Anvil"
      ha_mode  = "Standalone"
      networks = {
        eth0 = { roles = ["data", "mgmt"] }
      }
    }
  })
}

module "vm" {
  source = "../hs-vm"

  name                = "${var.prefix}Anvil1"
  computer_name       = "${var.prefix}Anvil"
  location            = var.location
  resource_group      = var.resource_group
  nic_ids             = [azurerm_network_interface.data.id]
  instance_type       = var.instance_type
  availability_set_id = var.availability_set_id
  availability_zone   = var.availability_zone
  ppg_id              = var.ppg_id
  image_id            = var.image_id
  marketplace_image   = var.marketplace_image
  os_disk_size        = var.boot_disk_size
  os_disk_type        = var.boot_disk_type
  data_disks = [
    {
      lun        = 1
      size       = var.metadata_disk_size
      type       = var.metadata_disk_type
      iops       = var.metadata_disk_iops
      throughput = var.metadata_disk_throughput
    }
  ]
  custom_data      = local.custom_data
  diag_storage_uri = var.diag_storage_uri
  admin_username   = var.admin_username
  admin_password   = var.admin_password
  tags             = var.tags
}
