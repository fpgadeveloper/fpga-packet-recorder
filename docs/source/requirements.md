# Requirements

## Hardware

* [ZCU106] Zynq UltraScale+ MPSoC evaluation kit
* [Ethernet FMC Max] (OP080) on the HPC0 connector
* [FPGA Drive FMC Gen4] (OP063) on the HPC1 connector
* One M.2 NVMe PCIe SSD in slot 1 of the FPGA Drive FMC Gen4. The ZCU106 HPC1 connector
  routes a single gigabit transceiver, so the SSD links at PCIe Gen3 x1, and the design
  switches off the 3.3 V supply of slot 2.
* A micro SD card (8 GB or more) for the Yocto image

## Software

* Vivado 2025.2 (Standard Edition)
* Vitis 2025.2 (`sdtgen`/`xsct`, used by the Yocto flow)
* A Linux build machine for the Yocto / EDF 2025.2 flow

## Target designs

{% for group in data.groups %}
{% set designs = data.designs | selectattr("group", "equalto", group.label) | selectattr("publish") | list %}
{% if designs %}
### {{ group.name }}

| Target board | Target design | SSD PCIe lanes | FPGA Drive FMC slot | Ethernet FMC Max slot | Yocto |
|--------------|---------------|----------------|---------------------|-----------------------|-------|
{% for d in designs %}| [{{ d.board }}]({{ d.link }}) | `{{ d.label }}` | {{ d.lanes[0][1:] }} | {{ d.ssd_connector }} | {{ d.eth_connector }} | {{ "Yes" if d.yocto else "No" }} |
{% endfor %}
{% endif %}
{% endfor %}

[ZCU106]: https://www.xilinx.com/zcu106
[Ethernet FMC Max]: https://docs.opsero.com/op080/datasheet/overview/
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
