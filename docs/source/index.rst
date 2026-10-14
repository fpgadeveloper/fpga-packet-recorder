.. FPGA Packet Recorder documentation master file.

FPGA Packet Recorder
====================

This is the documentation for the FPGA Packet Recorder reference design: lossless,
hardware-timestamped Gigabit Ethernet packet capture to an NVMe SSD, and replay, on a ZCU106
fitted with the `Ethernet FMC Max`_ and the `FPGA Drive FMC Gen4`_. Captures are controlled
from a web browser and downloaded as pcapng files that open directly in Wireshark.

.. toctree::
   :maxdepth: 2
   :caption: User Guide

   description
   requirements
   hardware_setup
   build_instructions
   yocto
   getting_started
   web_ui
   modes
   timestamping
   replay
   performance
   known_limitations
   troubleshooting
   revision_history

.. toctree::
   :maxdepth: 2
   :caption: Reference

   design
   capture_format
   software
   testing


.. _Ethernet FMC Max: https://docs.opsero.com/op080/datasheet/overview/
.. _FPGA Drive FMC Gen4: https://docs.opsero.com/op063/datasheet/overview/
