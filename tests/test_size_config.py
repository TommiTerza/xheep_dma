#!/usr/bin/env python3
# Author: Tommaso Terzano <tommaso.terzano@epfl.ch>
"""Check DMA size configuration defaults, overrides, and validation."""
from pathlib import Path
from types import SimpleNamespace
import unittest

import hjson
from mako.template import Template


class SizeConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.dma = SimpleNamespace(
            get_two_d=lambda: True, get_addr_mode=lambda: False,
            get_subaddr_mode=lambda: False, get_hw_fifo_mode=lambda: False,
            get_zero_padding=lambda: False)
        self.xheep = SimpleNamespace(get_base_peripheral_domain=lambda:
                                     SimpleNamespace(get_dma=lambda: self.dma))
        self.template = Template(filename=str(
            Path(__file__).resolve().parents[1] / 'data/xheep_dma.hjson.tpl'))

    def check_widths(self, expected, **options):
        config = hjson.loads(self.template.render(xheep=self.xheep, **options))
        parameters = {entry['name']: int(entry['default']) for entry in config['param_list']}
        registers = {entry['name']: entry for entry in config['registers']}
        for dimension, width in zip(('D1', 'D2'), expected):
            self.assertEqual(parameters[f'Size{dimension}Width'], width)
            self.assertEqual(registers[f'SIZE_{dimension}']['fields'][0]['bits'], f'{width - 1}:0')

    def test_defaults(self):
        self.check_widths((16, 16))

    def test_independent_widths_and_boundaries(self):
        for d1, d2 in [(13, 4), (1, 32), (32, 1)]:
            with self.subTest(d1=d1, d2=d2):
                self.check_widths((d1, d2), dma_size_d1_width=d1, dma_size_d2_width=d2)

    def test_getters_and_explicit_override(self):
        self.dma.get_size_d1_width = lambda: 13
        self.dma.get_size_d2_width = lambda: 4
        self.check_widths((13, 4))
        self.check_widths((12, 4), dma_size_d1_width=12)

    def test_slot_widths(self):
        for mask, counter in [(16, 8), (1, 1), (3, 4), (16, 32)]:
            with self.subTest(mask=mask, counter=counter):
                config = hjson.loads(self.template.render(
                    xheep=self.xheep, dma_slot_mask_width=mask,
                    dma_slot_wait_counter_width=counter))
                parameters = {entry['name']: int(entry['default']) for entry in config['param_list']}
                registers = {entry['name']: entry for entry in config['registers']}
                self.assertEqual(parameters['SlotMaskWidth'], mask)
                self.assertEqual(parameters['SlotWaitCounterWidth'], counter)
                rx, tx = registers['SLOT']['fields']
                self.assertEqual(rx['bits'], f'{mask - 1}:0')
                self.assertEqual(tx['bits'], f'{mask + 15}:16')
                self.assertEqual(registers['SLOT_WAIT_COUNTER']['fields'][0]['bits'], f'{counter - 1}:0')

    def test_slot_defaults_and_getters(self):
        config = hjson.loads(self.template.render(xheep=self.xheep))
        parameters = {entry['name']: int(entry['default']) for entry in config['param_list']}
        self.assertEqual(parameters['SlotMaskWidth'], 16)
        self.assertEqual(parameters['SlotWaitCounterWidth'], 8)
        self.dma.get_slot_mask_width = lambda: 3
        self.dma.get_slot_wait_counter_width = lambda: 4
        config = hjson.loads(self.template.render(xheep=self.xheep, dma_slot_mask_width=2))
        parameters = {entry['name']: int(entry['default']) for entry in config['param_list']}
        self.assertEqual(parameters['SlotMaskWidth'], 2)
        self.assertEqual(parameters['SlotWaitCounterWidth'], 4)

    def test_invalid_slot_widths(self):
        for name, maximum in [('mask', 16), ('wait_counter', 32)]:
            for width in (0, -1, maximum + 1, True, 1.5, '3', None):
                with self.subTest(name=name, width=width):
                    with self.assertRaisesRegex(ValueError, 'width must be an integer'):
                        self.template.render(xheep=self.xheep, **{f'dma_slot_{name}_width': width})

    def test_invalid_widths(self):
        for dimension in ('d1', 'd2'):
            for width in (0, -1, 33, True, 4.5, '13', None):
                with self.subTest(dimension=dimension, width=width):
                    with self.assertRaisesRegex(ValueError, 'size width must be an integer'):
                        self.template.render(xheep=self.xheep, **{f'dma_size_{dimension}_width': width})


if __name__ == '__main__':
    unittest.main()
