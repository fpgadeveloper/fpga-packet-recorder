# Build instructions

## Source code

The source code for the reference design is managed on this Github repository:

* [https://github.com/fpgadeveloper/fpga-packet-recorder](https://github.com/fpgadeveloper/fpga-packet-recorder)

To get the code, clone the repository **with its submodules** (the Ethernet MAC/PCS comes
from the Taxi submodule):
```
git clone --recursive https://github.com/fpgadeveloper/fpga-packet-recorder.git
cd fpga-packet-recorder
```

In an existing clone, run `git submodule update --init` before building.

## License requirements

The design uses no separately licensed IP. It can be built with the Vivado ML Standard
Edition **without a license**. The Taxi library (`submodules/taxi`) is licensed under the
CERN-OHL-S-2.0; see [Description](description.md#ip-cores-and-licensing).

## Target designs

{% for group in data.groups %}
{% set designs = data.designs | selectattr("group", "equalto", group.label) | selectattr("publish") | list %}
{% if designs %}
### {{ group.name }} designs

| Target board | Target design | Ethernet FMC Max slot | FPGA Drive FMC Gen4 slot | SSD PCIe lanes | Vivado Edition |
|--------------|---------------|-----------------------|--------------------------|----------------|----------------|
{% for d in designs %}| [{{ d.board }}]({{ d.link }}) | `{{ d.label }}` | {{ d.eth_connector }} | {{ d.ssd_connector }} | {{ d.lanes[0][1:] }} | {{ "Enterprise" if d.license else "Standard (free)" }} |
{% endfor %}
{% endif %}
{% endfor %}

The design runs Linux only: there is a Yocto flow and no PetaLinux or standalone (baremetal)
flow.

## Cross-platform build runner

All builds are driven by the `build.py` runner at the root of the repository. Each command
builds whatever it depends on, skips anything that is already built, and locates the AMD
tools itself, so there is no need to source the settings scripts beforehand.

On Linux and on Windows (git bash), run the commands with the `build.sh` shim. From Command
Prompt or PowerShell, use `build.bat` with the same arguments (for example
`build.bat xsa --target zcu106`).

To see the targets and the state of a build:

```
./build.sh list                     # the targets and their attributes
./build.sh status --target zcu106   # the per-stage artifact state
./build.sh clean --target zcu106    # delete the target's generated outputs
```

```{note}
The Linux image (Yocto) can only be built on a native Linux machine; the Vivado project and
XSA build on Windows too. On Windows, the runner refuses the Yocto stage up front and prints
the command to run on the Linux machine.
```

### Build the Vivado project

This command creates the Vivado project, generates the bitstream and exports the hardware to
an XSA file (`Vivado/zcu106/pktrec_wrapper.xsa`):

```
./build.sh xsa --target zcu106
```

To get the Vivado project and block design without a bitstream, for example to explore the
design in the Vivado GUI, run `./build.sh project --target zcu106` and open the project
from `Vivado/zcu106/`.

### Build the Yocto image

This builds the Yocto / EDF Linux image with the capture software, the recorder driver and
the web interface. It needs a native Linux machine with
[Google's `repo` tool](https://gerrit.googlesource.com/git-repo/) on the `PATH`. The XSA is
built first if it does not exist:

```
./build.sh yocto --target zcu106
```

The first build runs `repo sync` (several GB) and bitbake from scratch, and the workspace
occupies 40 to 60 GB; later builds are incremental. The outputs are gathered into
`Yocto/zcu106/images/linux/`. See [Yocto](yocto) for how the image is put together and how
to write it to the SD card.

#### Yocto offline build

To build offline (or faster), point the build at a locally extracted AMD sstate-cache mirror:

1. Download the sstate-cache artefacts ("sstate-cache & Downloads - 2025.2") from the AMD
   Embedded Design Tools download page and extract them to one location, for example
   `/home/user/yocto-sstate`, which then holds `aarch64`, `microblaze` and `downloads`.
2. Create a text file called `offline.txt` in the `Yocto` directory of the repository
   containing that path on a single line, with no trailing slash.

### Build everything

This builds the XSA, then the Yocto image, and packs the files to write to the SD card into
`bootimages/fpga-packet-recorder_zcu106_yocto-2025-2.zip`:

```
./build.sh all --target zcu106
```

### Build the software outside Yocto

The C programs and the kernel module are ordinary Makefile projects, so you can rebuild them
without the Yocto flow, for example on the board:

```
make -C sw/pktrec-apps                 # pktrec-cap, pktrec-export, pktrec-replay (needs liburing)
make -C sw/fdrec-apps                  # fdrec, fdplay, fdverify
make -C sw/fdrec-driver KERNEL_SRC=<configured kernel tree for the board's kernel>
```

`pktrec-phy`, `pktrec-tb` (`sw/pktrec-tools`) and `pktrec-web` (`sw/pktrec-web`) are Python 3
scripts that use only the standard library. `pktrec-export` also builds and runs on a PC,
so capture files can be converted off the board (see [Software](software.md#pktrec-export)).

### Simulate the custom RTL

The custom RTL in `Vivado/src/hdl/` has self-checking testbenches in `Vivado/src/sim/`. Run
them in the Vivado simulator with:

```
cd Vivado
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all
```

Each testbench prints `PASS` or `FAIL`. The testbenches are listed in
[Testing](testing.md#rtl-testbenches).
