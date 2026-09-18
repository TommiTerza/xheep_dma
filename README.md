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

## Transfer size widths

D1 and D2 register widths are independently configurable from 1 to 32 bits,
with 16-bit defaults. Pass `dma_size_d1_width` and `dma_size_d2_width` when
rendering `data/xheep_dma.hjson.tpl`, for example:

```python
Template(filename="data/xheep_dma.hjson.tpl").render(
    xheep=xheep, dma_size_d1_width=13, dma_size_d2_width=4)
```

The template also accepts `get_size_d1_width()` and `get_size_d2_width()` on the
DMA configuration object; explicit template arguments take precedence. Existing
configuration objects need no changes to retain the defaults. Regenerate the
register RTL, software headers, and register documentation after changing widths.
Pass the matching widths to the top-level `dma` instance, as with the dispatch
parameters:

```systemverilog
  .SIZE_D1_WIDTH(13),
  .SIZE_D2_WIDTH(4)
```

Both top-level parameters default to 16. The top module checks that they match
the generated register widths and passes the widths to its units. It also derives
the padding counter widths. `dma_pkg` contains only types.

Sizes remain direct element counts: D1 counts elements per row and D2 counts
rows. A width of N accepts counts up to `2**N - 1`; zero D1 does not start a
transfer. Register offsets and the 32-bit register bus remain unchanged.
For example, 13/4 bits can represent 4,096 words per row and eight rows
(16 KiB per row, 128 KiB total), but also larger counts up to 8,191/15.
These widths do not enforce a total byte limit or prevent address wraparound.

Read and address-mode counters use the configured widths. Write and padding
counters grow only when zero padding is enabled, enough to include two
63-element margins even for narrow size registers. D2 logic is unused when
2D support is disabled.

To test a reduced-width configuration, use:

```sh
python3 tests/run_dispatch.py --xheep-root /path/to/x-heep --size-d1-width 13 --size-d2-width 4
```

The regression checks maximum counts and, for small dimensions, maximum padding
on all sides in addition to the dispatch tests. Use 4/3 or 1/1 widths to exercise
padding carry bits and the smallest supported counters.

## Slot widths

The top-level `dma` parameters `SLOT_MASK_WIDTH` (1–16, default 16) and
`SLOT_WAIT_COUNTER_WIDTH` (1–32, default 8) configure the RX/TX mask registers
and the read/write slot wait counters. `SLOT_NUM` remains the number of connected
trigger inputs and must not exceed `SLOT_MASK_WIDTH`. With `SLOT_NUM=0`, slot
waiting is disabled and the one-bit placeholder input can be tied low.

Render the register template with matching `dma_slot_mask_width` and
`dma_slot_wait_counter_width` arguments, then regenerate register RTL and software
headers. The template also accepts `get_slot_mask_width()` and
`get_slot_wait_counter_width()` on the DMA configuration object. For example,
use widths 4 and 3 in both the template and top-level parameters for four-bit
masks and a wait count of 0–7. No configuration parameters are added to `dma_pkg`.

RX masks still start at bit 0 and TX masks at bit 16. Narrowing masks leaves
reserved bits between fields; register offsets do not change. Width checks
reject mismatches between the top-level parameters and generated registers.

```sh
python3 tests/run_dispatch.py --xheep-root /path/to/x-heep --slot-mask-width 4 --slot-wait-counter-width 3
```

The regression tests trigger blocking on both ports and zero/maximum waits
for counters up to eight bits wide.
Use `--slot-num 0 --lint-only` to check the configuration without trigger inputs.

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
