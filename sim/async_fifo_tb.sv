`timescale 1ns/1ps

module async_fifo_tb;

  localparam int DATA_W = 32;
  localparam int DEPTH  = 64;

  // Clocks
  logic wr_clk = 0;
  logic rd_clk = 0;

  // Resets
  logic wr_rst_n = 0;
  logic rd_rst_n = 0;

  // DUT I/O
  logic              wr_en;
  logic [DATA_W-1:0] wr_data;
  logic              wr_full;

  logic              rd_en;
  logic [DATA_W-1:0] rd_data;
  logic              rd_empty;

  // Instantiate DUT
  async_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(DEPTH),
    .SYNC_STAGES(2)
  ) dut (
    .wr_clk, .wr_rst_n, .wr_en, .wr_data, .wr_full,
    .rd_clk, .rd_rst_n, .rd_en, .rd_data, .rd_empty
  );

  // Clock generation: unrelated frequencies
  always #10  wr_clk = ~wr_clk; // 50 MHz
  always #6   rd_clk = ~rd_clk; // 83.33 MHz

  // Simple scoreboard (queue)
  mailbox #(logic [DATA_W-1:0]) exp_mb = new();

  // Track successful handshakes
  logic wr_fire, rd_fire;
  assign wr_fire = wr_en && !wr_full;
  assign rd_fire = rd_en && !rd_empty;

  // Because rd_data is registered on rd_fire, compare 1 cycle later
  logic              rd_fire_d;
  logic [DATA_W-1:0] exp_d;

  // Random control
  int unsigned seed = 32'hC0FFEE01;
  function automatic int unsigned urand();
    seed = seed * 32'd1664525 + 32'd1013904223;
    return seed;
  endfunction

  // Flag to stop write wide
   logic stop_writes;

  // Drive write side
  always_ff @(posedge wr_clk) begin
    if (!wr_rst_n) begin
      wr_en   <= 1'b0;
      wr_data <= '0;
    end else begin
      if (stop_writes) begin
        wr_en   <= 1'b0;
        wr_data <= wr_data;
      end else begin
      wr_en   <= (urand() % 10) < 6; // 0.6 probability to write
      wr_data <= urand();
      end
      if (wr_fire) begin
      exp_mb.put(wr_data);
      end
    end
  end

  // Drive read side
  always_ff @(posedge rd_clk) begin
    if (!rd_rst_n) begin
      rd_en <= 1'b0;
    end else begin
      rd_en <= (urand() % 20) < 11; // 0.55 probability to read
    end
  end

  // Check read data against scoreboard (1-cycle delayed)
  logic [DATA_W-1:0] tmp;

  always_ff @(posedge rd_clk) begin
    if (!rd_rst_n) begin
      rd_fire_d <= 1'b0;
      exp_d     <= '0;
    end else begin
      rd_fire_d <= rd_fire;

      if (rd_fire) begin
        if (!exp_mb.try_get(tmp)) begin
          $error("Scoreboard underflow: DUT read but mailbox empty");
          $fatal;
        end
        exp_d <= tmp;
      end

      if (rd_fire_d) begin
        if (rd_data !== exp_d) begin
          $error("DATA MISMATCH: got 0x%08x expected 0x%08x at t=%0t",
                 rd_data, exp_d, $time);
          $fatal;
        end
      end
    end
  end

  // Reset sequence + run
 
  initial begin
    stop_writes = 1'b0;
    wr_rst_n = 0;
    rd_rst_n = 0;

    #100;
    wr_rst_n = 1;
    #37;
    rd_rst_n = 1;

    #200000;

    // Drain phase: stop generating writes, keep reading
    @(posedge wr_clk);
      stop_writes = 1'b1;
    repeat (2000) @(posedge rd_clk);

    $display("Simulation done. Scoreboard remaining entries: %0d", exp_mb.num());
    $finish;
    end

endmodule
