# X-HEEP DMA

The configurable X-HEEP DMA. For the full documentation, refer to X-HEEP's online [documentation](https://x-heep.readthedocs.io/en/latest/Peripherals/DMA.html).

## Quick Start

To genrate the DMA RTL files:
1. Render the Mako templates inside [`data/`](./data/) with X-HEEP's [`mcu_gen.py`](https://github.com/x-heep/xheep_gen) or similar.
2. Make [`x-heep:ip:dma`](./dma.core) a dependency of your project, e.g.:
    ```yaml
    filesets:
      rtl:
        depend:
        - x-heep:ip:dma
        ...
    ```

The configuration registers RTL and the corresponding C header and documentation are automatically generated inside the `rtl`, `sw`, and `docs` directories. If you need these files in different locations in your project, you can `link -sr` those directories there (see X-HEEP for a usage example).
Alternatively, if your project does not rely on FuseSoC, you can use the included [`Makefile`](./Makefile) to generate the same files.

The X-HEEP DMA depends on `pulp-platform.org::common_cells`, so be sure that they are vendored in your project and FuseSoC detects the `common_cells.core` file.

## Dispatching

Dispatching is ported from the DMA vendored in `heepokranios`. Enable it through
`dma.get_dispatching()` and set `dma.get_ext_read_fifo_id_num()` to 1–32 before
rendering both templates. Older configuration objects without `get_dispatching()`
keep dispatch disabled. Regenerate the register RTL, C headers, and documentation
with the existing generator. The `dma` module exposes `EXT_READ_FIFO_ID_NUM` and `EXT_READ_FIFO_ID_BITS`
parameters and passes them to the units that need them. The count defaults to
one and the width defaults to `max(1, $clog2(EXT_READ_FIFO_ID_NUM))`.
Set these parameters at the X-HEEP instantiation using
`core_v_mini_mcu_pkg::DMA_EXT_READ_FIFO_ID_NUM` and
`core_v_mini_mcu_pkg::DMA_EXT_READ_FIFO_ID_BITS`. The supplied count must match
the generated dispatch register count.

Connect `ext_read_fifo_req_i`, `ext_read_fifo_req_id_i`, and
`ext_read_fifo_resp_o` to the sample producer. A sample is accepted on a clock edge
when `push` is high and `full` is low. Keep data and ID stable until accepted.
IDs range from zero to the configured count minus one; invalid IDs are
backpressured. `full` also stays high while dispatch is disabled or the DMA is
idle. The request's `pop` and `flush` fields are unused. Unused input ports may be
tied to zero and the response left open.

While the DMA is idle:

1. Set `DST_PTR_DISPATCH[id]` for each destination, the shared destination
   increments, data type, and dimensions. With one ID, reggen names the register
   `DST_PTR_DISPATCH`; otherwise it uses `DST_PTR_DISPATCH0`, etc.
2. Set `DISPATCH_EN` to one. Use single (`MODE=0`) or circular (`MODE=1`) mode,
   disable `HW_FIFO_EN`, and leave all padding sizes zero. Dispatch bypasses memory
   reads and padding; provide each sample in the low bits of the input word,
   already sign-extended if needed.
3. Write nonzero `SIZE_D1` last to start. Sizes apply independently to each ID;
   2D transfers also use `SIZE_D2` and the second destination increment.

Single mode completes when **the first ID** reaches its transfer size. Circular
mode independently reloads each completed destination and continues accepting
samples. Switching from circular to single mode stops at the next destination
completion. Configure other registers only while idle. Queued samples remaining
at completion are discarded when the next transfer starts.

In dispatch mode, `WINDOW_SIZE=N` raises an event every N accepted writes **per
ID**. `WINDOW_ID` accumulates pending IDs as a bit mask. Software acknowledges
serviced IDs by writing the remaining mask back; the window interrupt clears
once the mask is zero. Reading `WINDOW_IFR` alone does not acknowledge dispatch
windows. Concurrent new events take priority over software writes, so re-read
the mask after acknowledging it. `WINDOW_COUNT` exposes ID zero's current count.
With dispatch disabled, the existing window behavior is preserved.

The new registers are appended after `SLOT_WAIT_COUNTER`, preserving existing
register offsets. Use this repository's generated headers: dispatch offsets
are different from those in the original heepokranios register map. Ensure the
parent system's register address aperture covers the generated register block.

Run the standalone regression with Python Mako/HJSON, Verilator, a C++ toolchain,
and an X-HEEP checkout containing `common_cells` and `register_interface`:

```sh
python3 tests/run_dispatch.py --xheep-root /path/to/x-heep
```

For static checks without running simulations, add `--lint-only`.

The regression exercises dispatch-disabled and 1/3/32-ID builds, optional hardware features,
interleaved samples, write stalls, word/half-word writes, per-ID windows,
independent circular reloads, 2D transfers, and circular-to-single completion.
