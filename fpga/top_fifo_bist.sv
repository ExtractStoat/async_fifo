// DE10-Lite BIST for async_fifo.sv
//
// - Generates write traffic with a counter pattern (increments only on successful writes)
// - Generates read traffic (attempts reads increments expected only on successful reads)
// - Compares rd_data with expected value (1-cycle delay because FIFO rd_data is registered)
// - Latches error until reset
//
// Clocking:
// - wr_clk uses board clock (50MHz)
// - rd_clk uses a simple PLL (83.33MHz)

module top_fifo_bist #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 64
)(
  input  logic        wr_clk,
  input  logic        KEY,

  output logic [9:0]  LEDR
);

  // -----------------------------------------------------------------------------------------------
  // Clocks
  // -----------------------------------------------------------------------------------------------
  logic rd_clk;
  logic pll_locked;

  rd_clk	rd_clk_inst (
    .inclk0 ( wr_clk ),
    .c0 ( rd_clk ),
    .locked ( pll_locked )
    );

  // -----------------------------------------------------------------------------------------------
  // Resets (active-low)
  // -----------------------------------------------------------------------------------------------
  logic wr_rst_n, rd_rst_n; 
  // active-low reset input (keys include debounce filter)
  assign wr_rst_n = KEY & pll_locked; 
  assign rd_rst_n = KEY & pll_locked; 

  // -----------------------------------------------------------------------------------------------
  // DUT signals
  // -----------------------------------------------------------------------------------------------
  logic              wr_en;
  logic [DATA_W-1:0] wr_data;
  logic              wr_full;

  logic              rd_en;
  logic [DATA_W-1:0] rd_data;
  logic              rd_empty;

  async_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(DEPTH),
    .SYNC_STAGES(2)
  ) dut (
    .wr_clk   (wr_clk),
    .wr_rst_n (wr_rst_n),
    .wr_en    (wr_en),
    .wr_data  (wr_data),
    .wr_full  (wr_full),

    .rd_clk   (rd_clk),
    .rd_rst_n (rd_rst_n),
    .rd_en    (rd_en),
    .rd_data  (rd_data),
    .rd_empty (rd_empty)
  );

  // -----------------------------------------------------------------------------------------------
  // BIST pattern + gating
  // -----------------------------------------------------------------------------------------------
  // Static data pattern. Counter increments only on successful writes.
  logic [DATA_W-1:0] wr_counter;
  // Data pattern is current counter value
  assign wr_data = wr_counter;
  // Semi-random gating: simple LFSR in each domain.
  logic [15:0] lfsr_w, lfsr_r;

  // Handshakes
  logic wr_fire, rd_fire;
  assign wr_fire = wr_en && !wr_full;
  assign rd_fire = rd_en && !rd_empty;

  // Write side attempt writes most cycles, but gate with LFSR to create bursts
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      lfsr_w     <= 16'hACE1;
      wr_en      <= 1'b0;
      wr_counter <= '0;
    end else begin
      // 16-bit Fibonacci LFSR
      lfsr_w <= {lfsr_w[14:0], lfsr_w[15] ^ lfsr_w[13] ^ lfsr_w[12] ^ lfsr_w[10]};

      // ~70% attempt rate (tune by changing mask/compare)
      wr_en <= (lfsr_w[7:0] < 8'd180);

      if (wr_fire) begin
        wr_counter <= wr_counter + 1;
      end
    end
  end

  // Read side attempt reads often, gated to produce independent behavior
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      lfsr_r <= 16'h1D0F;
      rd_en  <= 1'b0;
    end else begin
      lfsr_r <= {lfsr_r[14:0], lfsr_r[15] ^ lfsr_r[14] ^ lfsr_r[12] ^ lfsr_r[3]};

      // ~65% attempt rate
      rd_en <= (lfsr_r[7:0] < 8'd166);
    end
  end

  // -----------------------------------------------------------------------------------------------
  // Checker (1-cycle delay compare)
  // -----------------------------------------------------------------------------------------------
  logic [DATA_W-1:0] exp_counter;   // expected next value to read
  logic [DATA_W-1:0] exp_d;         // expected value captured on rd_fire
  logic              rd_fire_d;     // delayed rd_fire (compare phase)
  logic              error_latched;

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      exp_counter   <= '0;
      exp_d         <= '0;
      rd_fire_d     <= 1'b0;
      error_latched <= 1'b0;
    end else begin
      rd_fire_d <= rd_fire;

      // On successful read handshake, capture expected value for next-cycle compare
      if (rd_fire) begin
        exp_d       <= exp_counter;
        exp_counter <= exp_counter + 1;
      end

      // Compare on the cycle after rd_fire, because FIFO registers rd_data on rd_fire
      if (rd_fire_d) begin
        if (rd_data !== exp_d) begin
          error_latched <= 1'b1;
        end
      end
    end
  end

  // -----------------------------------------------------------------------------------------------
  // Activity / heartbeat indicators
  // -----------------------------------------------------------------------------------------------
  logic [23:0] rd_alive_cnt, wr_alive_cnt;
  logic        rd_alive_blink, wr_alive_blink, wr_fire_blink, rd_fire_blink;
  logic [25:0] wr_fire_cnt, rd_fire_cnt;

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_alive_cnt   <= '0;
      rd_alive_blink <= 1'b0;
      rd_fire_cnt    <= '0;
      rd_fire_blink  <= 1'b0;
    end else begin
      rd_alive_cnt <= rd_alive_cnt + 1;
      if (rd_fire) begin
        rd_fire_cnt   <= rd_fire_cnt + 1;
      end
      if (rd_alive_cnt == 24'd0) rd_alive_blink <= ~rd_alive_blink;
      if (rd_fire_cnt == 25'd0)   rd_fire_blink <= ~rd_fire_blink; 
    end
  end

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
      if (!wr_rst_n) begin
        wr_alive_cnt    <= '0;
        wr_alive_blink  <= 1'b0;
        wr_fire_cnt     <= '0;
        wr_fire_blink   <= 1'b0;
      end else begin
        wr_alive_cnt  <= wr_alive_cnt + 1;
        if (wr_fire) begin
          wr_fire_cnt   <= wr_fire_cnt + 1;
        end
        if (wr_alive_cnt == 24'd0) wr_alive_blink <= ~wr_alive_blink;
        if (wr_fire_cnt == 25'd0)  wr_fire_blink  <= ~wr_fire_blink;
      end
    end

  // LED Mapping
  always_comb begin

    LEDR[0]   = error_latched;  // mismatch latched
    LEDR[1]   = wr_full;        // only really visible with clock/gate differences 
    LEDR[2]   = rd_empty;       // only really visible with clock/gate differences 

    LEDR[3]   = wr_fire_blink;  // pulses as writes attempts continue 
    LEDR[4]   = rd_fire_blink;  // pulses as read attempts continue 

    LEDR[5]   = ~wr_rst_n;
    LEDR[6]   = ~rd_rst_n;

    LEDR[7]   = 1'b0;

    LEDR[8]   = wr_alive_blink; // blinks at  ~1hz
    LEDR[9]   = rd_alive_blink; // blinks at  ~1hz
  end

endmodule