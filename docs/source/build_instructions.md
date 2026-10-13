# Build instructions

## Source code

```
git clone --recursive https://github.com/fpgadeveloper/fpga-packet-recorder.git
cd fpga-packet-recorder
```

## Build runner

All builds are driven by `build.py` at the repo root through the `build.sh` (Linux, git
bash) or `build.bat` (Windows) shim. The runner finds Vivado and Vitis in their standard
install locations and sets up the environment each stage needs.

| Command | Builds |
|---------|--------|
| `./build.sh xsa --target zcu106` | Vivado project, bitstream and XSA (`Vivado/zcu106/pktrec_wrapper.xsa`) |
| `./build.sh yocto --target zcu106` | Yocto / EDF image (Linux only; builds the XSA first if needed) |
| `./build.sh package --target zcu106` | gathers the boot files into `bootimages/` |
| `./build.sh all --target zcu106` | all of the above |
| `./build.sh status --target zcu106` | shows which artifacts exist |
