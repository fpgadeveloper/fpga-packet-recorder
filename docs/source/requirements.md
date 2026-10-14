# Requirements

## Hardware

* [ZCU106] Zynq UltraScale+ MPSoC evaluation kit
* [Ethernet FMC Max] (OP080) on the **HPC0** connector
* [FPGA Drive FMC Gen4] (OP063) on the **HPC1** connector
* One M.2 M-key NVMe PCIe SSD in **slot 1** of the FPGA Drive FMC Gen4. The ZCU106 HPC1
  connector routes a single gigabit transceiver, so the SSD links at PCIe Gen3 x1, and the
  design switches off the 3.3 V supply of slot 2. The SSD's sustained write rate (after its
  SLC cache is full) should be at least 500 MB/s to record four ports at line rate. The design
  was measured with a Samsung 980 PRO 1TB (see [Performance](performance)).
* A micro SD card (8 GB or larger) for the Linux image
* The ZCU106 USB-UART cable, for the console
* An Ethernet cable from the ZCU106's own RJ45 port to a network with a DHCP server (the web
  interface is served there)
* Ethernet cables (CAT-5e or better) for the Ethernet FMC Max ports. The ports are
  1000BASE-T: the devices connected to them must support 1 Gb/s (see [Port modes](modes)).
* A PC on the same network, with a web browser and [Wireshark](https://www.wireshark.org)

Optional, for the self-tests and the timestamp calibration: a short cable between P2 and P3
(see [Hardware setup](hardware_setup.md#loopback-cable-for-self-tests)).

## Software

To build the design:

* Vivado 2025.2 (the Standard Edition, which needs no license, supports the ZCU106 device)
* Vitis 2025.2 (provides `sdtgen`/`xsct`, used by the Yocto flow)
* A Linux build machine for the Yocto / EDF 2025.2 flow, with
  [Google's repo tool](https://gerrit.googlesource.com/git-repo/) on the `PATH` (see
  [Yocto](yocto))

The Vivado project and XSA can also be built on Windows. Pre-built boot images are not
required: everything builds from a clean clone (see [Build instructions](build_instructions)).

To use and test the design, on the PC:

* Wireshark (or `tshark` / `capinfos`) to open the pcapng files
* Python 3 for the test scripts in `test/` (standard library only; `scapy` and `tcpreplay`
  are optional traffic sources, see [Testing](testing))

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
