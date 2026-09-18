#!/usr/bin/env python3
# Author: Tommaso Terzano <tommaso.terzano@epfl.ch>
"""Render register variants and simulate DMA dispatch using local X-HEEP dependencies."""
import argparse
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace

from mako.template import Template


def run(command, log):
    result = subprocess.run([str(arg) for arg in command], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"Command failed: {' '.join(map(str, command))}\n{result.stdout}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xheep-root', type=Path, required=True)
    parser.add_argument('--lint-only', action='store_true',
                        help='Check RTL without building or running simulations')
    parser.add_argument('--size-d1-width', type=int, default=None)
    parser.add_argument('--size-d2-width', type=int, default=None)
    parser.add_argument('--slot-mask-width', type=int, default=None)
    parser.add_argument('--slot-wait-counter-width', type=int, default=None)
    parser.add_argument('--slot-num', type=int, default=None)
    args = parser.parse_args()
    width_options = {name: value for name, value in
                     [('dma_size_d1_width', args.size_d1_width),
                      ('dma_size_d2_width', args.size_d2_width),
                      ('dma_slot_mask_width', args.slot_mask_width),
                      ('dma_slot_wait_counter_width', args.slot_wait_counter_width)] if value is not None}
    root = Path(__file__).resolve().parents[1]
    vendor = args.xheep_root.resolve() / 'hw/vendor/pulp_platform'
    common = vendor / 'common_cells'
    registers = vendor / 'register_interface/vendor/lowrisc_opentitan'
    with tempfile.TemporaryDirectory(prefix='dma-dispatch-') as directory:
        for ids, features, two_d in [
                (ids, features, two_d)
                for ids, features in [(0, False), (0, True), (1, False), (3, False), (3, True), (32, False)]
                for two_d in (False, True)]:
            build = Path(directory) / f'ids{ids}-features{int(features)}-2d{int(two_d)}'
            build.mkdir()
            dma = SimpleNamespace(
                get_two_d=lambda: two_d,
                get_dispatching=lambda: bool(ids), get_ext_read_fifo_id_num=lambda: ids,
                get_addr_mode=lambda: features, get_subaddr_mode=lambda: features,
                get_hw_fifo_mode=lambda: features, get_zero_padding=lambda: features)
            xheep = SimpleNamespace(get_base_peripheral_domain=lambda:
                                    SimpleNamespace(get_dma=lambda: dma))
            for template, output in [('xheep_dma.hjson.tpl', 'dma.hjson'),
                                     ('dma_conf.svh.tpl', 'dma_conf.svh')]:
                (build / output).write_text(Template(filename=str(root / 'data' / template)).render(xheep=xheep, **width_options))
            run(['python3', registers / 'util/regtool.py', '-r', '-t', build,
                 build / 'dma.hjson'], build / 'reggen.log')
            sources = [build / 'dma_reg_pkg.sv', root / 'rtl/dma_pkg.sv',
                       registers / 'src/prim_subreg_arb.sv', registers / 'src/prim_subreg.sv',
                       registers / 'src/prim_subreg_ext.sv', common / 'src/fifo_v3.sv',
                       build / 'dma_reg_top.sv', *sorted((root / 'rtl/dma_units').rglob('*.sv')),
                       root / 'rtl/dma.sv', root / 'tests/dma_dispatch_tb.sv']
            run(['verilator', '--lint-only' if args.lint_only else '--binary',
                 '--timing', '--assert', '-Wno-fatal',
                 '--top-module', 'dma_dispatch_tb',
                 *([] if args.slot_num is None else [f'-GSLOT_NUM={args.slot_num}']),
                 '-I' + str(build),
                 '-I' + str(common / 'include'),
                 '-I' + str(vendor / 'register_interface/include'), '--Mdir', build / 'obj', '-j', '2',
                 *sources], build / 'build.log')
            warnings = [line for line in (build / 'build.log').read_text().splitlines()
                        if line.startswith('%Warning')]
            for warning in warnings:
                print(warning)
            if not args.lint_only:
                run([build / 'obj/Vdma_dispatch_tb'], build / 'simulation.log')
            check = 'lint' if args.lint_only else 'simulation'
            print(f'PASS ({check}): dispatch IDs={ids}, optional features={features}, 2D={two_d}')


if __name__ == '__main__':
    main()
