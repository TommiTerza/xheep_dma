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
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    vendor = args.xheep_root.resolve() / 'hw/vendor/pulp_platform'
    common = vendor / 'common_cells'
    registers = vendor / 'register_interface/vendor/lowrisc_opentitan'
    with tempfile.TemporaryDirectory(prefix='dma-dispatch-') as directory:
        for ids, features in [(0, False), (1, False), (3, False), (3, True), (32, False)]:
            build = Path(directory) / f'ids{ids}-features{int(features)}'
            build.mkdir()
            dma = SimpleNamespace(
                get_dispatching=lambda: bool(ids), get_ext_read_fifo_id_num=lambda: ids,
                get_addr_mode=lambda: features, get_subaddr_mode=lambda: features,
                get_hw_fifo_mode=lambda: features, get_zero_padding=lambda: features)
            xheep = SimpleNamespace(get_base_peripheral_domain=lambda:
                                    SimpleNamespace(get_dma=lambda: dma))
            for template, output in [('xheep_dma.hjson.tpl', 'dma.hjson'),
                                     ('dma_conf.svh.tpl', 'dma_conf.svh')]:
                (build / output).write_text(Template(filename=str(root / 'data' / template)).render(xheep=xheep))
            run(['python3', registers / 'util/regtool.py', '-r', '-t', build,
                 build / 'dma.hjson'], build / 'reggen.log')
            sources = [build / 'dma_reg_pkg.sv', root / 'rtl/dma_pkg.sv',
                       registers / 'src/prim_subreg_arb.sv', registers / 'src/prim_subreg.sv',
                       registers / 'src/prim_subreg_ext.sv', common / 'src/fifo_v3.sv',
                       build / 'dma_reg_top.sv', *sorted((root / 'rtl/dma_units').rglob('*.sv')),
                       root / 'rtl/dma.sv', root / 'tests/dma_dispatch_tb.sv']
            run(['verilator', '--lint-only' if args.lint_only else '--binary',
                 '--timing', '--assert', '-Wno-fatal',
                 '--top-module', 'dma_dispatch_tb', '-I' + str(build),
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
            print(f'PASS ({check}): dispatch IDs={ids}, optional features={features}')


if __name__ == '__main__':
    main()
