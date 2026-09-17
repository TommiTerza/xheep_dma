/*
 * Copyright 2024 EPFL
 * Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Info: Direct Memory Access (DMA) channel module.
 */

module dma
  import dma_reg_pkg::*;
#(
    parameter int FIFO_DEPTH = 4,
    parameter int RVALID_FIFO_DEPTH = 1,
    parameter int unsigned SLOT_NUM = 0,
    parameter type reg_req_t = logic,
    parameter type reg_rsp_t = logic,
    parameter type obi_req_t = logic,
    parameter type obi_resp_t = logic,
    parameter type fifo_resp_t = logic,
    parameter type fifo_req_t = logic,
    parameter int unsigned EXT_READ_FIFO_ID_NUM = 1,
    parameter int unsigned EXT_READ_FIFO_ID_BITS =
        (EXT_READ_FIFO_ID_NUM > 1) ? $clog2(EXT_READ_FIFO_ID_NUM) : 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic clk_gate_en_ni,

    input logic ext_dma_stop_i,
    input logic hw_fifo_done_i,

    input  reg_req_t reg_req_i,
    output reg_rsp_t reg_rsp_o,

    output obi_req_t  dma_read_req_o,
    input  obi_resp_t dma_read_resp_i,

    output obi_req_t  dma_write_req_o,
    input  obi_resp_t dma_write_resp_i,

    output obi_req_t  dma_addr_req_o,
    input  obi_resp_t dma_addr_resp_i,

    input  fifo_resp_t hw_fifo_resp_i,
    output fifo_req_t  hw_fifo_req_o,

    input logic [SLOT_NUM-1:0] trigger_slot_i,

    input dma_hw2reg_t external_hw2reg_i,

    output logic dma_done_intr_o,
    output logic dma_window_intr_o,

    output logic dma_ready_o,
    output logic dma_done_o,

    input  fifo_req_t ext_read_fifo_req_i,
    output fifo_resp_t ext_read_fifo_resp_o,
    input logic [EXT_READ_FIFO_ID_BITS-1:0] ext_read_fifo_req_id_i
);

  `include "dma_conf.svh"

  /*_________________________________________________________________________________________________________________________________ */

  /* Signals declaration */

  /* Gated clock */
  logic clk_cg;

  /* Registers */
  dma_reg2hw_t reg2hw;
  dma_hw2reg_t hw2reg;

  /* General signals */
  logic dma_processing_unit_on;

  logic dma_start;
  logic dma_start_pending;
  logic dma_done;
  logic dma_write_done_override;
  logic dma_read_done_override;

`ifdef DISPATCH_EN
  logic [EXT_READ_FIFO_ID_NUM-1:0] window_event;
  logic [31:0] window_counter [EXT_READ_FIFO_ID_NUM-1:0];
`else
  logic window_event;
  logic [31:0] window_counter;
`endif

  logic circular_mode;
  logic address_mode;
`ifdef HW_FIFO_MODE_EN
  logic hw_fifo_mode;
`else
  logic unused_hw_fifo_done;
  assign unused_hw_fifo_done = hw_fifo_done_i;
`endif
`ifndef DISPATCH_EN
  logic unused_ext_read_fifo_req_id;
  assign unused_ext_read_fifo_req_id = ^ext_read_fifo_req_id_i;
`endif
  logic dispatch_en;

  /* Buffer signals */
  fifo_req_t read_buffer_req;
  fifo_req_t read_addr_buffer_req;
  fifo_req_t write_buffer_req;

  logic [EXT_READ_FIFO_ID_BITS-1:0] read_fifo_req_id;
  logic [EXT_READ_FIFO_ID_BITS-1:0] write_fifo_req_id;

  fifo_resp_t read_buffer_resp;
  fifo_resp_t read_addr_buffer_resp;
  fifo_resp_t write_buffer_resp;

  logic data_in_req;
  logic data_in_we;
  logic [3:0] data_in_be;
  logic [31:0] data_in_addr;
  logic data_in_gnt;
  logic data_in_rvalid;
  logic [31:0] data_in_rdata;

  logic data_addr_in_req;
  logic data_addr_in_we;
  logic [3:0] data_addr_in_be;
  logic [31:0] data_addr_in_addr;
  logic data_addr_in_gnt;
  logic data_addr_in_rvalid;
  logic [31:0] data_addr_in_rdata;

  logic data_out_req;
  logic data_out_we;
  logic [3:0] data_out_be;
  logic [31:0] data_out_addr;
  logic [31:0] data_out_wdata;
  logic data_out_gnt;
  logic data_out_rvalid;
  logic [31:0] data_out_rdata;

  /* Interrupt Flag Register signals */
  logic transaction_ifr;
  logic dma_done_intr_n;
  logic dma_done_intr;
  logic window_ifr;
  logic dma_window_intr;
  logic dma_window_intr_n;

  /* Buffer unit signals */
  logic general_buffer_flush;
  logic read_buffer_flush;

  logic read_buffer_full;
  logic read_buffer_empty;
  logic read_buffer_alm_full;
  logic read_buffer_pop;
  logic [31:0] read_buffer_input;
  logic [31:0] read_buffer_output;

  logic read_addr_buffer_full;
  logic read_addr_buffer_empty;
  logic read_addr_buffer_alm_full;
  logic [31:0] read_addr_buffer_output;

  logic write_buffer_full;
  logic write_buffer_empty;
  logic write_buffer_alm_full;
  logic write_buffer_push;
  logic [31:0] write_buffer_output;
  logic [31:0] write_buffer_input;

  /* Trigger signals */
  logic wait_for_rx;
  logic wait_for_tx;
  logic enable_wait_for_rx;
  logic enable_wait_for_tx;

  /* FSM states */
  enum {
    DMA_READY,
    DMA_STARTING,
    DMA_RUNNING
  }
      dma_state_q, dma_state_d;

  /*_________________________________________________________________________________________________________________________________ */

  /* Module instantiation */

  /* Clock gating cell */

`ifndef FPGA_SYNTHESIS
`ifndef VERILATOR
  tc_clk_gating clk_gating_cell (
      .clk_i,
      .en_i(clk_gate_en_ni),
      .test_en_i(1'b0),
      .clk_o(clk_cg)
  );

`else
  assign clk_cg = clk_i & clk_gate_en_ni;
`endif

`else
  assign clk_cg = clk_i & clk_gate_en_ni;
`endif

  /* Registers */
  dma_reg_top #(
      .reg_req_t(reg_req_t),
      .reg_rsp_t(reg_rsp_t)
  ) dma_reg_top_i (
      .clk_i(clk_cg),
      .rst_ni,
      .reg_req_i,
      .reg_rsp_o,
      .reg2hw,
      .hw2reg,
      .devmode_i(1'b1)
  );

  assign dma_ready_o = hw2reg.status.ready.d;

  /* Buffer unit */
  dma_buffer_unit #(
      .EXT_READ_FIFO_ID_BITS(EXT_READ_FIFO_ID_BITS),
      .FIFO_DEPTH(FIFO_DEPTH),
      .fifo_req_t(fifo_req_t),
      .fifo_resp_t(fifo_resp_t)
  ) dma_buffer_unit_i (
      .clk_i(clk_cg),
      .rst_ni,

      .dma_start_i(dma_start),

      .reg2hw_i(reg2hw),

      .read_buffer_req_i(read_buffer_req),
      .read_addr_buffer_req_i(read_addr_buffer_req),
      .read_fifo_req_id_i(read_fifo_req_id),

      .write_buffer_req_i(write_buffer_req),
      .write_fifo_req_id_o(write_fifo_req_id),

      .read_buffer_resp_o(read_buffer_resp),
      .read_addr_buffer_resp_o(read_addr_buffer_resp),
      .write_buffer_resp_o(write_buffer_resp),

      .hw_fifo_resp_i,
      .hw_fifo_req_o
  );

  /* Read unit */
  dma_read_unit #(
      .RVALID_FIFO_DEPTH(RVALID_FIFO_DEPTH)
  ) dma_read_unit_i (
      .clk_i(clk_cg),
      .rst_ni,

      .reg2hw_i(reg2hw),

      .dma_start_i(dma_start && !dispatch_en),
      .dma_done_i(dma_done),
      .dma_done_override_i(dma_read_done_override),

      .wait_for_rx_i(wait_for_rx),
      .enable_wait_for_rx_i(enable_wait_for_rx),
      .slot_wait_counter_i(reg2hw.slot_wait_counter.q),

      .read_buffer_full_i(read_buffer_full),
      .read_buffer_alm_full_i(read_buffer_alm_full),

      .read_buffer_input_o(read_buffer_input),

      .data_in_gnt_i(data_in_gnt),
      .data_in_rvalid_i(data_in_rvalid),
      .data_in_rdata_i(data_in_rdata),

      .data_in_req_o(data_in_req),
      .data_in_we_o(data_in_we),
      .data_in_be_o(data_in_be),
      .data_in_addr_o(data_in_addr),
      .general_buffer_flush_o(read_buffer_flush)
  );

  /* Read address unit */
`ifdef ADDR_MODE_EN
  dma_read_addr_unit dma_read_addr_unit_i (
      .clk_i(clk_cg),
      .rst_ni,

      .reg2hw_i(reg2hw),

      .dma_start_i(dma_start),
      .dma_done_override_i(dma_write_done_override),

      .read_addr_buffer_full_i(read_addr_buffer_full),
      .read_addr_buffer_alm_full_i(read_addr_buffer_alm_full),

      .data_addr_in_gnt_i (data_addr_in_gnt),
      .data_addr_in_req_o (data_addr_in_req),
      .data_addr_in_we_o  (data_addr_in_we),
      .data_addr_in_be_o  (data_addr_in_be),
      .data_addr_in_addr_o(data_addr_in_addr)
  );
`else
  assign data_addr_in_req  = '0;
  assign data_addr_in_we   = '0;
  assign data_addr_in_be   = '0;
  assign data_addr_in_addr = '0;
`endif


  /* DMA processing unit */
`ifdef ZERO_PADDING_EN
  logic padding_write_push;
  logic padding_read_pop;
  logic [31:0] padding_write_data;

  dma_processing_unit dma_processing_unit_i (
      .clk_i(clk_cg),
      .rst_ni,

      .reg2hw_i(reg2hw),

      .dma_processing_unit_on_i(dma_processing_unit_on && !dispatch_en),
      .dma_start_i(dma_start),

      .read_buffer_empty_i(read_buffer_empty),
      .write_buffer_full_i(write_buffer_full),
      .write_buffer_alm_full_i(write_buffer_alm_full),

      .read_buffer_output_i(read_buffer_output),

      .write_buffer_push_o(padding_write_push),
      .read_buffer_pop_o  (padding_read_pop),

      .write_buffer_input_o(padding_write_data)
  );

  /* Dispatch carries one ID per sample and must bypass the global padding counter. */
  always_comb begin
    write_buffer_input = padding_write_data;
    write_buffer_push = padding_write_push;
    read_buffer_pop = padding_read_pop;
    if (dispatch_en) begin
      write_buffer_input = read_buffer_output;
      write_buffer_push = !read_buffer_empty && !write_buffer_full &&
                          !write_buffer_alm_full && dma_processing_unit_on;
      read_buffer_pop = write_buffer_push;
    end
  end
`else
  logic read_buffer_en;
  logic write_buffer_en;

  /* Read FIFO pop enable */
  assign read_buffer_en  = (read_buffer_empty == 1'b0);

  /* Write FIFO push enable */
  assign write_buffer_en = (write_buffer_full == 1'b0 && write_buffer_alm_full == 1'b0);

  always_comb begin
    if (read_buffer_en && write_buffer_en && dma_processing_unit_on == 1'b1) begin
      write_buffer_input = read_buffer_output;
      write_buffer_push  = 1'b1;
      read_buffer_pop    = 1'b1;
    end else begin
      write_buffer_input = '0;
      write_buffer_push  = 1'b0;
      read_buffer_pop    = 1'b0;
    end
  end
`endif


  /* Write unit */
  dma_write_unit #(
      .EXT_READ_FIFO_ID_NUM(EXT_READ_FIFO_ID_NUM),
      .EXT_READ_FIFO_ID_BITS(EXT_READ_FIFO_ID_BITS)
  ) dma_write_unit_i (
      .clk_i(clk_cg),
      .rst_ni,

      .reg2hw_i(reg2hw),

      .dma_start_i(dma_start),
      .wait_for_tx_i(wait_for_tx),
      .enable_wait_for_tx_i(enable_wait_for_tx),
      .slot_wait_counter_i(reg2hw.slot_wait_counter.q),

      .dma_done_o(dma_done),
      .dma_done_override_i(dma_write_done_override),

      .write_buffer_empty_i(write_buffer_empty),
      .read_addr_buffer_empty_i(read_addr_buffer_empty),

      .write_buffer_output_i(write_buffer_output),
      .read_addr_buffer_output_i(read_addr_buffer_output),

      .write_fifo_req_id_i(write_fifo_req_id),

      .data_out_gnt_i(data_out_gnt),
      .data_out_rvalid_i(data_out_rvalid),

      .data_out_req_o(data_out_req),
      .data_out_we_o(data_out_we),
      .data_out_be_o(data_out_be),
      .data_out_addr_o(data_out_addr),
      .data_out_wdata_o(data_out_wdata)
  );

  /*_________________________________________________________________________________________________________________________________ */

  /* FSMs instantiation */

  //
  // Main DMA state machine
  //
  // READY   : idle, waiting for a write pulse to size registered in `dma_start_pending`
  // STARTING: load transaction data
  // RUNNING : waiting for transaction finish
  //           when `dma_done` rises either enter ready or restart in circular mode
  //

  always_comb begin
    dma_state_d = dma_state_q;
    case (dma_state_q)
      DMA_READY: begin
        if (dma_start_pending) begin
          dma_state_d = DMA_STARTING;
        end
      end
      DMA_STARTING: begin
        dma_state_d = DMA_RUNNING;
      end
      DMA_RUNNING: begin
        if (dma_done) begin
          if (circular_mode) dma_state_d = DMA_STARTING;
          else dma_state_d = DMA_READY;
        end
      end
    endcase
  end

  /* Update DMA state */
  always_ff @(posedge clk_cg, negedge rst_ni) begin
    if (~rst_ni) begin
      dma_state_q <= DMA_READY;
    end else begin
      dma_state_q <= dma_state_d;
    end
  end

  /* DMA pulse start when dma_start register is written */
  always_ff @(posedge clk_cg or negedge rst_ni) begin : proc_dma_start
    if (~rst_ni) begin
      dma_start_pending <= 1'b0;
    end else begin
      if (dma_start == 1'b1) begin
        dma_start_pending <= 1'b0;
      end else if ((reg2hw.size_d1.qe & |reg2hw.size_d1.q) || (reg2hw.hw_config_mode.q && external_hw2reg_i.size_d1.de && (external_hw2reg_i.size_d1.d > '0))) begin
        dma_start_pending <= 1'b1;
      end
    end
  end

  /* Transaction IFR update */
  always_ff @(posedge clk_cg, negedge rst_ni) begin : proc_ff_transaction_ifr
    if (~rst_ni) begin
      transaction_ifr <= '0;
    end else begin
      if (reg2hw.interrupt_en.transaction_done.q == 1'b1) begin
        // Enter here only if the transaction_done interrupt is enabled
        if (dma_done == 1'b1) begin
          transaction_ifr <= 1'b1;
        end else if (reg2hw.transaction_ifr.re == 1'b1) begin
          // If the IFR bit is read, we must clear the transaction_ifr
          transaction_ifr <= 1'b0;
        end
      end
    end
  end

  /* Delayed transaction interrupt signals */
  always_ff @(posedge clk_cg, negedge rst_ni) begin : proc_ff_intr
    if (~rst_ni) begin
      dma_done_intr_n <= '0;
    end else begin
      dma_done_intr_n <= dma_done_intr;
    end
  end

  /* Window IFR update */
  always_ff @(posedge clk_cg, negedge rst_ni) begin : proc_ff_window_ifr
    if (~rst_ni) begin
      window_ifr <= '0;
    end else begin
      if (reg2hw.interrupt_en.window_done.q == 1'b1) begin
        if (|window_event == 1'b1) begin
          window_ifr <= 1'b1;
`ifdef DISPATCH_EN
        end else if ((dispatch_en && reg2hw.window_id.q == '0) ||
                     (!dispatch_en && reg2hw.window_ifr.re)) begin
          /* All pending channel events have been acknowledged. */
`else
        end else if (reg2hw.window_ifr.re == 1'b1) begin
          /* Without dispatch, reading the flag acknowledges the window event. */
`endif
          window_ifr <= 1'b0;
        end
      end
    end
  end

  /* Delayed window interrupt signals */
  always_ff @(posedge clk_cg, negedge rst_ni) begin : proc_ff_window_intr
    if (~rst_ni) begin
      dma_window_intr_n <= '0;
    end else begin
      dma_window_intr_n <= dma_window_intr;
    end
  end

  /* Window event counter */
`ifdef DISPATCH_EN
  always_ff @(posedge clk_cg, negedge rst_ni) begin : proc_dma_window_cnt
    if (~rst_ni) begin
      for (int i = 0; i < EXT_READ_FIFO_ID_NUM; i++) begin
        window_counter[i] <= '0;
      end
    end else begin
      if (|reg2hw.window_size.q) begin
        if ((dispatch_en && dma_start) || (circular_mode && reg2hw.window_size.qe) || (~circular_mode && (dma_start | dma_done))) begin
          for (int i = 0; i < EXT_READ_FIFO_ID_NUM; i++) begin
            window_counter[i] <= '0;
          end
        end else if (data_out_gnt && (!dispatch_en || data_out_req)) begin
          if (window_event[write_fifo_req_id] == 1'b1) begin
            window_counter[write_fifo_req_id] <= '0;
          end else begin
            window_counter[write_fifo_req_id] <= window_counter[write_fifo_req_id] + 'h1;
          end
        end
      end else if (dispatch_en) begin
        for (int i = 0; i < EXT_READ_FIFO_ID_NUM; i++) begin
          window_counter[i] <= '0;
        end
      end
    end
  end
`else
  always_ff @(posedge clk_cg, negedge rst_ni) begin : proc_dma_window_cnt
    if (~rst_ni) begin
      window_counter <= '0;
    end else begin
      if (|reg2hw.window_size.q) begin
        if ( (circular_mode && reg2hw.window_size.qe) || (~circular_mode && (dma_start | dma_done))) begin
          window_counter <= '0;
        end else if (data_out_gnt) begin
          if (window_event) begin
            window_counter <= '0;
          end else begin
            window_counter <= window_counter + 'h1;
          end
        end
      end
    end
  end
`endif

  /* Update Processing Unit start signal */
  always_ff @(posedge clk_cg, negedge rst_ni) begin
    if (~rst_ni) begin
      dma_processing_unit_on <= 1'b0;
    end else begin
      if (dma_start == 1'b1) begin
        dma_processing_unit_on <= 1'b1;
      end else if (dma_done == 1'b1) begin
        dma_processing_unit_on <= 1'b0;
      end
    end
  end

  /* HW FIFO done signal override logic */
`ifdef HW_FIFO_MODE_EN
  assign dma_write_done_override = (write_buffer_empty & hw_fifo_done_i & hw_fifo_mode) || ext_dma_stop_i;
`else
  assign dma_write_done_override = ext_dma_stop_i;
`endif

  assign dma_read_done_override = ext_dma_stop_i;


  /*_________________________________________________________________________________________________________________________________ */

  /* Signal assignments */

  /* General signals */
  assign dma_done_o = dma_done;
  assign dma_start = (dma_state_q == DMA_STARTING);

  /* OBI signals */
  assign dma_read_req_o.req = data_in_req;
  assign dma_read_req_o.we = data_in_we;
  assign dma_read_req_o.be = data_in_be;
  assign dma_read_req_o.addr = data_in_addr;
  assign dma_read_req_o.wdata = 32'h0;

  assign data_in_gnt = dma_read_resp_i.gnt;
  assign data_in_rvalid = dma_read_resp_i.rvalid;
  assign data_in_rdata = dma_read_resp_i.rdata;

  assign dma_addr_req_o.req = data_addr_in_req;
  assign dma_addr_req_o.we = data_addr_in_we;
  assign dma_addr_req_o.be = data_addr_in_be;
  assign dma_addr_req_o.addr = data_addr_in_addr;
  assign dma_addr_req_o.wdata = 32'h0;

  assign data_addr_in_gnt = dma_addr_resp_i.gnt;
  assign data_addr_in_rvalid = dma_addr_resp_i.rvalid;
  assign data_addr_in_rdata = dma_addr_resp_i.rdata;

  assign dma_write_req_o.req = data_out_req;
  assign dma_write_req_o.we = data_out_we;
  assign dma_write_req_o.be = data_out_be;
  assign dma_write_req_o.addr = data_out_addr;
  assign dma_write_req_o.wdata = data_out_wdata;

  assign data_out_gnt = dma_write_resp_i.gnt;
  assign data_out_rvalid = dma_write_resp_i.rvalid;
  assign data_out_rdata = dma_write_resp_i.rdata;

  assign general_buffer_flush = read_buffer_flush || (dispatch_en && dma_start);

  /* FIFO signals */
  assign read_buffer_req.push = dispatch_en ? (ext_read_fifo_req_i.push && !ext_read_fifo_resp_o.full) : data_in_rvalid;
  assign read_buffer_req.pop = read_buffer_pop;
  assign read_buffer_req.flush = general_buffer_flush;
  assign read_buffer_req.data = dispatch_en ? ext_read_fifo_req_i.data : read_buffer_input;

`ifdef DISPATCH_EN
  assign read_fifo_req_id = ext_read_fifo_req_id_i;
`else
  assign read_fifo_req_id = 0;
`endif

  assign read_buffer_empty = read_buffer_resp.empty;
  assign read_buffer_full = read_buffer_resp.full;
  assign read_buffer_alm_full = read_buffer_resp.alm_full;
  assign read_buffer_output = read_buffer_resp.data;

  assign read_addr_buffer_req.push = data_addr_in_rvalid;
  assign read_addr_buffer_req.pop = data_out_gnt && address_mode;
  assign read_addr_buffer_req.flush = general_buffer_flush;
  assign read_addr_buffer_req.data = data_addr_in_rdata;

  assign read_addr_buffer_empty = read_addr_buffer_resp.empty;
  assign read_addr_buffer_full = read_addr_buffer_resp.full;
  assign read_addr_buffer_alm_full = read_addr_buffer_resp.alm_full;
  assign read_addr_buffer_output = read_addr_buffer_resp.data;

  assign write_buffer_req.push = write_buffer_push;
  /* An idle OBI grant must not consume a sample during a dispatch reload. */
  assign write_buffer_req.pop = (dma_state_q == DMA_RUNNING) && data_out_gnt &&
                                (!dispatch_en || data_out_req);
  assign write_buffer_req.flush = general_buffer_flush;
  assign write_buffer_req.data = write_buffer_input;

  assign write_buffer_empty = write_buffer_resp.empty;
  assign write_buffer_full = write_buffer_resp.full;
  assign write_buffer_alm_full = write_buffer_resp.alm_full;
  assign write_buffer_output = write_buffer_resp.data;

  /* EXT READ FIFO response signals */
  assign ext_read_fifo_resp_o.empty = read_buffer_empty;
  assign ext_read_fifo_resp_o.full = read_buffer_full || !dispatch_en ||
                                   (dma_state_q != DMA_RUNNING) || dma_done ||
                                   (int'(ext_read_fifo_req_id_i) >= EXT_READ_FIFO_ID_NUM);
  assign ext_read_fifo_resp_o.alm_full = read_buffer_alm_full;
  assign ext_read_fifo_resp_o.data = read_buffer_output;

  assign dma_done_intr = transaction_ifr;
  assign dma_done_intr_o = dma_done_intr_n;
  assign dma_window_intr = window_ifr;
  assign dma_window_intr_o = dma_window_intr_n;

  /* hw2reg update logic */
  always_comb begin
    hw2reg = '0;

    if (reg2hw.hw_config_mode.q) begin
      hw2reg = external_hw2reg_i;
    end
    //these registers are controlled only by the DMA and never externally
    //thus, they are overwritten
    hw2reg.transaction_ifr.d = transaction_ifr;
    hw2reg.window_ifr.d = window_ifr;
    hw2reg.status.ready.d = (dma_state_q == DMA_READY);
    hw2reg.status.window_done.d = |window_event;
`ifdef DISPATCH_EN
    /* Preserve pending IDs until software acknowledges them. */
    hw2reg.window_id.d = reg2hw.window_id.q | window_event;
    hw2reg.window_id.de = dispatch_en && |window_event;
    hw2reg.window_count.d = window_counter[0][7:0];
`else
    hw2reg.window_count.d = window_counter[7:0];
`endif
  end

  assign circular_mode = reg2hw.mode.q == 1;
  assign address_mode = reg2hw.mode.q == 2;
`ifdef HW_FIFO_MODE_EN
  assign hw_fifo_mode = reg2hw.hw_fifo_en.q;
`endif
`ifdef DISPATCH_EN
  assign dispatch_en = reg2hw.dispatch_en.q;
`else
  assign dispatch_en = 1'b0;
`endif

  assign wait_for_rx = |(reg2hw.slot.rx_trigger_slot.q[SLOT_NUM-1:0] & (~trigger_slot_i));
  assign wait_for_tx = |(reg2hw.slot.tx_trigger_slot.q[SLOT_NUM-1:0] & (~trigger_slot_i));
  assign enable_wait_for_rx = |(reg2hw.slot.rx_trigger_slot.q[SLOT_NUM-1:0]);
  assign enable_wait_for_tx = |(reg2hw.slot.tx_trigger_slot.q[SLOT_NUM-1:0]);

  /* Logic for window counter */
`ifdef DISPATCH_EN
  for (genvar i = 0; i < EXT_READ_FIFO_ID_NUM; i++) begin : gen_window_event
    assign window_event[i] = |reg2hw.window_size.q & data_out_gnt & (!dispatch_en || data_out_req) &
                             (i == write_fifo_req_id) &
                             (window_counter[i] == {19'h0, reg2hw.window_size.q} - (dispatch_en ? 32'd1 : 32'd0));
  end
`else
  assign window_event = |reg2hw.window_size.q & data_out_gnt & (window_counter == {19'h0, reg2hw.window_size.q});
`endif

endmodule : dma
