# ============================================================
# DSX data-services node(s) on Azure - the ARM template's DSX
# loop: <prefix>Dsx1..N, each with a data NIC, boot disk and
# N data disks (luns 0..count-1), joined to the cluster via
# cluster.metadata.ips in custom data.
# ============================================================

locals {
  nodes = { for i in range(1, var.node_count + 1) : tostring(i) => i }

  data_disks = [
    for j in range(var.data_disk_count) : {
      lun  = j
      size = var.data_disk_size
      type = var.data_disk_type
    }
  ]

  # ARM dsxCustomData (verbatim structure). storage.options is [] unless
  # striping is enabled - exactly like the template's createArray() call.
  custom_data = {
    for idx, i in local.nodes : idx => jsonencode({
      cluster = {
        domainname = var.domain
        metadata = {
          ips = ["${var.metadata_ip}/${var.subnet_prefixlen}"]
        }
      }
      node = {
        features    = ["portal", "storage"]
        add_volumes = true
        storage = {
          options = var.data_disk_striping ? ["raid0"] : []
        }
        hostname = "${var.prefix}Dsx${idx}"
        networks = {
          eth0 = { roles = ["data", "mgmt"] }
        }
      }
    })
  }
}

resource "azurerm_public_ip" "dsx" {
  for_each = var.public_ip ? local.nodes : {}

  name                = "${var.prefix}Dsx${each.key}PubIP"
  location            = var.location
  resource_group_name = var.resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "data" {
  for_each = local.nodes

  name                = "${var.prefix}Dsx${each.key}DataIface"
  location            = var.location
  resource_group_name = var.resource_group
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.data_subnet_id
    private_ip_address_allocation = length(var.static_ips) >= tonumber(each.key) ? "Static" : "Dynamic"
    private_ip_address            = length(var.static_ips) >= tonumber(each.key) ? var.static_ips[tonumber(each.key) - 1] : null
    public_ip_address_id          = var.public_ip ? azurerm_public_ip.dsx[each.key].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "data" {
  for_each = local.nodes

  network_interface_id      = azurerm_network_interface.data[each.key].id
  network_security_group_id = var.nsg_id
}

module "vm" {
  source   = "../hs-vm"
  for_each = local.nodes

  name                = "${var.prefix}Dsx${each.key}"
  computer_name       = "${var.prefix}Dsx${each.key}"
  location            = var.location
  resource_group      = var.resource_group
  nic_ids             = [azurerm_network_interface.data[each.key].id]
  instance_type       = var.instance_type
  availability_set_id = var.availability_set_id
  availability_zone   = var.availability_zone
  ppg_id              = var.ppg_id
  image_id            = var.image_id
  marketplace_image   = var.marketplace_image
  os_disk_size        = var.boot_disk_size
  os_disk_type        = var.boot_disk_type
  data_disks          = local.data_disks
  custom_data         = local.custom_data[each.key]
  diag_storage_uri    = var.diag_storage_uri
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = var.tags
}
