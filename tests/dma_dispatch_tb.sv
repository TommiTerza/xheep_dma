/* Author: Tommaso Terzano <tommaso.terzano@epfl.ch> */
module dma_dispatch_tb #(
    parameter int unsigned SLOT_NUM = dma_reg_pkg::SlotMaskWidth
);
  import dma_reg_pkg::*;
  `include "dma_conf.svh"
`ifdef DISPATCH_EN
  localparam int unsigned DispatchIdCount = dma_reg_pkg::ExtReadFifoIdNum;
`else
  localparam int unsigned DispatchIdCount = 1;
`endif
  localparam int unsigned DispatchIdWidth = (DispatchIdCount > 1) ? $clog2(DispatchIdCount) : 1;
  typedef struct packed {
    logic valid, write;
    logic [3:0] wstrb;
    logic [31:0] addr, wdata;
  } reg_req_t;
  typedef struct packed {
    logic error, ready;
    logic [31:0] rdata;
  } reg_rsp_t;
  typedef struct packed {
    logic req, we;
    logic [3:0] be;
    logic [31:0] addr, wdata;
  } obi_req_t;
  typedef struct packed {
    logic gnt, rvalid;
    logic [31:0] rdata;
  } obi_resp_t;
  typedef struct packed {
    logic push, pop, flush;
    logic [31:0] data;
  } fifo_req_t;
  typedef struct packed {
    logic full, empty, alm_full;
    logic [31:0] data;
  } fifo_resp_t;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;
  reg_req_t reg_req;
  reg_rsp_t reg_rsp;
  obi_req_t read_req, write_req, addr_req;
  obi_resp_t read_resp, write_resp;
  fifo_req_t input_req;
  fifo_resp_t input_resp;
  logic [DispatchIdWidth-1:0] input_id;
  logic [(SLOT_NUM > 0 ? SLOT_NUM : 1)-1:0] trigger_slots = '1;
  logic ready, done, window_irq;
  logic allow_writes = 1;
  logic expect_dispatch = 0;
  logic circular = 0;
  int writes = 0;
  int expected_offset[DispatchIdCount];
  int transfer_size = 3;
  int stride = 4;
  int cycles = 0;
  int reads = 0;
  int source_columns = 0;
  int source_rows = 1;
  int padding_columns = 0;
  int padding_rows = 0;
  bit check_slot_delay = 0;
  bit slot_reads = 0;
  int slot_delay = 0;
  int last_read_cycle = -1;
  int last_write_cycle = -1;

  dma #(.SIZE_D1_WIDTH(dma_reg_pkg::SizeD1Width),
        .SIZE_D2_WIDTH(dma_reg_pkg::SizeD2Width),
        .SLOT_MASK_WIDTH(dma_reg_pkg::SlotMaskWidth),
        .SLOT_WAIT_COUNTER_WIDTH(dma_reg_pkg::SlotWaitCounterWidth),
        .EXT_READ_FIFO_ID_NUM(DispatchIdCount), .EXT_READ_FIFO_ID_BITS(DispatchIdWidth),
        .RVALID_FIFO_DEPTH(4), .SLOT_NUM(SLOT_NUM), .reg_req_t(reg_req_t), .reg_rsp_t(reg_rsp_t),
        .obi_req_t(obi_req_t), .obi_resp_t(obi_resp_t),
        .fifo_req_t(fifo_req_t), .fifo_resp_t(fifo_resp_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .clk_gate_en_ni(1'b1),
    .ext_dma_stop_i(1'b0), .hw_fifo_done_i(1'b0),
    .reg_req_i(reg_req), .reg_rsp_o(reg_rsp),
    .dma_read_req_o(read_req), .dma_read_resp_i(read_resp),
    .dma_write_req_o(write_req), .dma_write_resp_i(write_resp),
    .dma_addr_req_o(addr_req), .dma_addr_resp_i('0),
    .ext_read_fifo_req_i(input_req), .ext_read_fifo_resp_o(input_resp),
    .ext_read_fifo_req_id_i(input_id), .hw_fifo_resp_i('0), .hw_fifo_req_o(),
    .trigger_slot_i(trigger_slots), .external_hw2reg_i('0),
    .dma_done_intr_o(), .dma_window_intr_o(window_irq), .dma_ready_o(ready), .dma_done_o(done)
  );

  assign read_resp.gnt = read_req.req;
  assign read_resp.rdata = 32'h12345678;
  assign write_resp.gnt = write_req.req && allow_writes && (cycles % 3 != 0);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      read_resp.rvalid <= 0;
      write_resp.rvalid <= 0;
      cycles <= 0;
    end else begin
      read_resp.rvalid <= read_resp.gnt;
      write_resp.rvalid <= write_resp.gnt;
      cycles <= cycles + 1;
    end
  end

  always @(posedge clk) begin
    if (rst_n && read_req.req && read_resp.gnt) begin
      reads++;
      if (check_slot_delay && slot_reads && last_read_cycle >= 0) begin
        assert (cycles - last_read_cycle >= slot_delay + (slot_delay == 0 ? 2 : 3))
          else $fatal(1, "RX slot wait counter expired early");
      end
      last_read_cycle = cycles;
    end
    if (rst_n && write_req.req && write_resp.gnt) begin
      if (check_slot_delay && !slot_reads && last_write_cycle >= 0) begin
        assert (cycles - last_write_cycle >= slot_delay + (slot_delay == 0 ? 2 : 3))
          else $fatal(1, "TX slot wait counter expired early");
      end
      last_write_cycle = cycles;
    end
    if (rst_n && expect_dispatch) begin
      assert (!read_req.req) else $fatal(1, "Dispatch issued a memory read");
      if (write_req.req && write_resp.gnt) begin
        automatic int id = (write_req.addr - 'h1000) / 'h100;
        assert (id >= 0 && id < DispatchIdCount) else $fatal(1, "Invalid destination");
        assert (write_req.addr == 'h1000 + id * 'h100 + expected_offset[id] * stride)
          else $fatal(1, "Wrong pointer for ID %0d: %h", id, write_req.addr);
        assert (write_req.wdata == (stride == 4 ? 32'habc00000 + 32'(id) :
                                   (32'(id + 1) << (8 * (write_req.addr % 4)))))
          else $fatal(1, "Data and ID lost alignment");
        assert (write_req.be == (stride == 4 ? 4'hf : 4'(3 << (write_req.addr % 4))))
          else $fatal(1, "Wrong byte enable");
        expected_offset[id]++;
        if (circular && expected_offset[id] == transfer_size) expected_offset[id] = 0;
        writes++;
      end
    end else if (rst_n && write_req.req && write_resp.gnt) begin
      assert (write_req.addr == 'h8000 + writes * 4) else $fatal(1, "Legacy pointer changed");
      if (padding_columns != 0 || padding_rows != 0) begin
        automatic int columns = source_columns + 2 * padding_columns;
        automatic int row = writes / columns;
        automatic int column = writes % columns;
        automatic bit is_padding = row < padding_rows || row >= padding_rows + source_rows ||
                                   column < padding_columns || column >= padding_columns + source_columns;
        assert (write_req.wdata == (is_padding ? 32'b0 : 32'h12345678))
          else $fatal(1, "Wrong padded data at row %0d column %0d", row, column);
      end else begin
        assert (write_req.wdata == 32'h12345678) else $fatal(1, "Legacy data changed");
      end
      writes++;
    end
  end

  task automatic write_register(input logic [31:0] address, value);
    @(negedge clk);
    reg_req = '{valid:1, write:1, wstrb:'1, addr:address, wdata:value};
    @(posedge clk);
    assert (reg_rsp.ready && !reg_rsp.error) else $fatal(1, "Register write failed: %h", address);
    @(negedge clk);
    reg_req = '0;
  endtask

  task automatic send_sample(input int id);
    @(negedge clk);
    input_id = DispatchIdWidth'(id);
    input_req.data = stride == 4 ? 32'habc00000 + 32'(id) : 32'(id + 1);
    input_req.push = 1;
    #1;
    while (input_resp.full) begin
      @(negedge clk);
      #1;
    end
    @(negedge clk);
    input_req.push = 0;
  endtask

  task automatic reset_dma;
    @(negedge clk);
    rst_n = 0;
    reg_req = '0;
    input_req = '0;
    input_id = '0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    writes = 0;
    reads = 0;
    trigger_slots = '1;
    check_slot_delay = 0;
    last_read_cycle = -1;
    last_write_cycle = -1;
    padding_columns = 0;
    padding_rows = 0;
    foreach (expected_offset[i]) expected_offset[i] = 0;
  endtask

  initial begin
    #10000000;
    $fatal(1, "Test timed out");
  end

  task automatic check_slots(input int delay_cycles, input bit rx);
    reset_dma();
    check_slot_delay = 1;
    slot_delay = delay_cycles;
    slot_reads = rx;
    trigger_slots = '0;
    write_register(32'(DMA_DST_PTR_OFFSET), 'h8000);
    write_register(32'(DMA_SLOT_OFFSET), 1 << ((rx ? 0 : 16) + SLOT_NUM - 1));
    write_register(32'(DMA_SLOT_WAIT_COUNTER_OFFSET), 32'(delay_cycles));
    write_register(32'(DMA_SIZE_D1_OFFSET), 3);
    repeat (8) begin
      @(negedge clk);
      assert (!write_req.req && (!rx || !read_req.req)) else $fatal(1, "Inactive slot failed to block DMA");
    end
    /* Only the selected highest slot is asserted; other slots must not block. */
    trigger_slots = (SLOT_NUM > 0 ? SLOT_NUM : 1)'(1 << (SLOT_NUM - 1));
    wait (done);
    @(negedge clk);
    assert (reads == 3 && writes == 3) else $fatal(1, "Wrong slotted transfer length");
    check_slot_delay = 0;
  endtask

  task automatic check_size_limits(input bit two_d, padded);
    reset_dma();
    source_columns = (1 << SizeD1Width) - 1;
    source_rows = two_d ? (1 << SizeD2Width) - 1 : 1;
    padding_columns = padded ? 63 : 0;
    padding_rows = padded && two_d ? 63 : 0;
    write_register(32'(DMA_DST_PTR_OFFSET), 'h8000);
    write_register(32'(DMA_DST_PTR_INC_D1_OFFSET), 4);
    write_register(32'(DMA_SRC_PTR_INC_D1_OFFSET), 4);
`ifdef DMA_2D_EN
    write_register(32'(DMA_DIM_CONFIG_OFFSET), 32'(two_d));
    write_register(32'(DMA_DST_PTR_INC_D2_OFFSET), 4);
    write_register(32'(DMA_SRC_PTR_INC_D2_OFFSET), 4);
    write_register(32'(DMA_SIZE_D2_OFFSET), 32'(source_rows));
`endif
`ifdef ZERO_PADDING_EN
    write_register(32'(DMA_PAD_LEFT_OFFSET), 32'(padding_columns));
    write_register(32'(DMA_PAD_RIGHT_OFFSET), 32'(padding_columns));
`ifdef DMA_2D_EN
    write_register(32'(DMA_PAD_TOP_OFFSET), 32'(padding_rows));
    write_register(32'(DMA_PAD_BOTTOM_OFFSET), 32'(padding_rows));
`endif
`endif
    write_register(32'(DMA_SIZE_D1_OFFSET), 32'(source_columns));
    wait (done);
    @(negedge clk);
    assert (reads == source_columns * source_rows) else $fatal(1, "Wrong read count at size limit");
    assert (writes == (source_columns + 2 * padding_columns) * (source_rows + 2 * padding_rows))
      else $fatal(1, "Wrong write count at size limit");
    repeat (4) @(negedge clk);
    assert (ready) else $fatal(1, "DMA did not return to idle");
  endtask

  initial begin
    if (SLOT_NUM > 0 && SizeD1Width >= 2) begin
      for (int rx = 0; rx < 2; rx++) begin
        check_slots(0, 1'(rx));
        check_slots(SlotWaitCounterWidth <= 8 ? (1 << SlotWaitCounterWidth) - 1 : 3, 1'(rx));
      end
    end
    /* Exercise terminal counts and padding carry bits with bounded simulation time. */
    if (SizeD1Width <= 16) check_size_limits(0, 0);
`ifdef DMA_2D_EN
    if (SizeD1Width <= 8 && SizeD2Width <= 8) check_size_limits(1, 0);
`endif
`ifdef ZERO_PADDING_EN
    if (SizeD1Width <= 8) check_size_limits(0, 1);
`ifdef DMA_2D_EN
    if (SizeD1Width <= 8 && SizeD2Width <= 8) check_size_limits(1, 1);
`endif
`endif
    if (SizeD1Width < 2 || SizeD2Width < 2) $finish;
    reset_dma();
    write_register(32'(DMA_DST_PTR_OFFSET), 'h8000);
    write_register(32'(DMA_DST_PTR_INC_D1_OFFSET), 4);
    write_register(32'(DMA_SRC_PTR_INC_D1_OFFSET), 4);
    write_register(32'(DMA_SIZE_D1_OFFSET), 3);
    wait (done);
    @(negedge clk);
    assert (writes == 3) else $fatal(1, "Legacy transfer length changed");
`ifdef DISPATCH_EN
`ifdef DMA_2D_EN
    for (int phase = 0; phase < 4; phase++) begin
`else
    for (int phase = 0; phase < 3; phase++) begin
`endif
      reset_dma();
      expect_dispatch = 1;
      circular = phase != 0;
      stride = phase == 2 ? 2 : 4;
      transfer_size = phase == 3 ? 6 : 3;
      for (int id = 0; id < DispatchIdCount; id++) begin
        write_register(32'(DMA_DISPATCH_EN_OFFSET) + 4 + id * 4, 'h1000 + id * 'h100);
      end
      write_register(32'(DMA_DST_PTR_INC_D1_OFFSET), 32'(stride));
      write_register(32'(DMA_DST_DATA_TYPE_OFFSET), stride == 2 ? 1 : 0);
`ifdef DMA_2D_EN
      write_register(32'(DMA_DST_PTR_INC_D2_OFFSET), 32'(stride));
      write_register(32'(DMA_DIM_CONFIG_OFFSET), phase == 3 ? 1 : 0);
      write_register(32'(DMA_SIZE_D2_OFFSET), phase == 3 ? 2 : 0);
`endif
      write_register(32'(DMA_DISPATCH_EN_OFFSET), 1);
      write_register(32'(DMA_MODE_OFFSET), circular ? 1 : 0);
      write_register(32'(DMA_WINDOW_SIZE_OFFSET), 2);
      write_register(32'(DMA_INTERRUPT_EN_OFFSET), 2);
      write_register(32'(DMA_SIZE_D1_OFFSET), 3);
      wait (!input_resp.full);
      if (phase == 0) begin
        /* No reset between windows: IDs must remain paired under a stalled writer. */
        allow_writes = 0;
        fork
          begin
            repeat (20) @(negedge clk);
            allow_writes = 1;
          end
          begin
            for (int sample_index = 0; sample_index < 2; sample_index++) begin
              for (int id = 0; id < DispatchIdCount; id++) send_sample(id);
            end
          end
        join
        wait (writes == 2 * DispatchIdCount);
        wait (window_irq);
        assert (dut.reg2hw.window_id.q == {DispatchIdCount{1'b1}})
          else $fatal(1, "Missing per-ID window event");
        write_register(32'(DMA_WINDOW_ID_OFFSET), 0);
        repeat (4) @(negedge clk);
        assert (!window_irq) else $fatal(1, "Window acknowledgement failed");
        send_sample(0);
        wait (done);
        @(negedge clk);
        assert (writes == 2 * DispatchIdCount + 1) else $fatal(1, "First-ID completion failed");
      end else begin
        for (int sample_index = 0; sample_index < 2 * transfer_size + 2; sample_index++) begin
          for (int id = 0; id < DispatchIdCount; id++) send_sample(id);
        end
        wait (writes == (2 * transfer_size + 2) * DispatchIdCount);
        assert (!done) else $fatal(1, "Circular transfer terminated");
        /* Stop circular operation; the first completed destination ends the transfer. */
        circular = 0;
        write_register(32'(DMA_MODE_OFFSET), 0);
        repeat (transfer_size - 2) send_sample(0);
        wait (done);
      end
    end
`endif
    $display("DMA dispatch regression passed");
    $finish;
  end
endmodule
